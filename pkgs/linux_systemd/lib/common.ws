use value
use fs
use shell

// Helpers shared by linux_systemd's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// :unmanaged means "do not look at this aspect" — it is what lets one
// resource install a unit without also deciding whether it runs.
fn desired_state(params: Value) -> Result[string, string] {
    let s = param_str(params, "state", "unmanaged")
    if s == "running" || s == "stopped" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'state' value '" + s + "' (expected :running, :stopped or :unmanaged)")
}

fn desired_enabled(params: Value) -> Result[string, string] {
    let e = param_str(params, "enabled", "unmanaged")
    if e == "enabled" || e == "disabled" || e == "unmanaged" { return Ok(e) }
    Err("invalid 'enabled' value '" + e + "' (expected :enabled, :disabled or :unmanaged)")
}

// A failed command's error: stderr, else stdout, always with the exit code.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

fn run(what: string, cmd: string) -> Result[unit, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(())
}

// A unit name, or one segment of a unit_file path: no '/', no leading '.'
// (which covers `.` and `..`), no leading '-' (systemctl would read an
// option), no whitespace, and no glob characters (systemctl matches unit
// patterns). '\' stays legal: systemd-escape writes `\x2d` into names.
fn require_segment(key: string, s: string) -> Result[unit, string] {
    if s == "" { return Err("'" + key + "' must not be empty or contain empty path segments") }
    if s.contains("/") { return Err("'" + key + "' must not contain '/': " + s) }
    if s.starts_with(".") { return Err("'" + key + "' must not start with '.': " + s) }
    if s.starts_with("-") { return Err("'" + key + "' must not start with '-': " + s) }
    if s.contains("\n") || s.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    for c in ["*", "?", "[", "]", " ", "\t"] {
        if s.contains(c) { return Err("'" + key + "' must not contain '" + c + "': " + s) }
    }
    Ok(())
}

fn has_systemctl() -> Result[bool, string] {
    Ok(shell::bash("command -v systemctl >/dev/null 2>&1", Value::Null)?.success)
}

// systemctl can read unit files without systemd, but starting, stopping and
// daemon-reload need it running as PID 1.
fn systemd_running() -> bool { fs::is_dir("/run/systemd/system") }

fn daemon_reload() -> Result[unit, string] { run("systemctl daemon-reload", "systemctl daemon-reload") }

// Whether systemd has seen a newer unit file or drop-in than the one it
// loaded. An error (a template, a name systemd rejects) counts as no.
fn needs_reload(unit: string) -> Result[bool, string] {
    let out = shell::bash("systemctl show -p NeedDaemonReload --value " + q(unit), Value::Null)?
    Ok(out.success && out.stdout.trim() == "yes")
}

// A file that cannot be read as text (gone, or not UTF-8) is simply not
// the wanted content.
fn has_content(p: string, body: string) -> bool {
    match fs::read(p) {
        Ok(s) => s == body,
        Err(e) => false,
    }
}

fn mtime(p: string) -> int {
    match fs::metadata(p) {
        Ok(m) => {
            if let Some(v) = m.get("modified") { return v.as_int().unwrap_or(0) }
            0
        },
        Err(e) => 0,
    }
}
