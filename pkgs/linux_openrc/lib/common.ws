use value
use fs
use shell

// Helpers shared by linux_openrc's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
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
// resource install a service without also deciding whether it runs.
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

// A failed command's error: stderr, else stdout (rc-service reports
// there), always with the exit code.
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

// The name is the basename of /etc/init.d/<name> and of its runlevel
// links, part of a runlevel glob, and an operand to rc-service and
// rc-update — so no path separators, no leading '.' (which covers `.` and
// `..`), no leading '-', and no glob metacharacters. Runlevel names are
// directories under /etc/runlevels and follow the same rules.
fn require_name(key: string, name: string) -> Result[unit, string] {
    if name == "" { return Err("missing '" + key + "' parameter") }
    if name.contains("/") || name.contains("\\") { return Err("'" + key + "' must not contain '/' or '\\': " + name) }
    if name.starts_with(".") { return Err("'" + key + "' must not start with '.': " + name) }
    if name.starts_with("-") { return Err("'" + key + "' must not start with '-': " + name) }
    if name.contains("\n") || name.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    for c in ["*", "?", "[", "]", " ", "\t"] {
        if name.contains(c) { return Err("'" + key + "' must not contain '" + c + "': " + name) }
    }
    Ok(())
}

// Whether every exec bit is set: `make_executable` uses `chmod a+x`, which
// ignores the umask, so this is exactly what it leaves behind. A symlinked
// script is judged by its target.
fn executable(p: string) -> Result[bool, string] {
    let m = fs::metadata(p)?
    if let Some(l) = m.get("is_symlink") {
        if l.as_bool().unwrap_or(false) { return Ok(shell::bash("test -x " + q(p), Value::Null)?.success) }
    }
    let mode = 0
    if let Some(v) = m.get("mode") { mode = v.as_int().unwrap_or(0) }
    Ok((mode / 64) % 2 == 1 && (mode / 8) % 2 == 1 && mode % 2 == 1)
}

fn make_executable(p: string) -> Result[unit, string] { run("chmod a+x " + p, "chmod a+x " + q(p)) }

// A file that cannot be read as text (gone, or not UTF-8) is simply not
// the wanted content.
fn has_content(p: string, body: string) -> bool {
    match fs::read(p) {
        Ok(s) => s == body,
        Err(e) => false,
    }
}
