use value
use fs
use shell

// Helpers shared by linux_runit's resources. Imported with `use common`;
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

// A failed command's error: stderr, else stdout (sv reports there),
// always with the exit code.
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

// The name is a directory under sv_dir and a link under service_dir, so
// no path separators, no leading '.' (which covers `.` and `..`: `.` would
// make :absent delete sv_dir itself), no leading '-' and nothing a shell or
// glob would read specially.
fn require_name(name: string) -> Result[unit, string] {
    if name == "" { return Err("missing 'name' parameter") }
    if name.contains("/") || name.contains("\\") { return Err("'name' must not contain '/' or '\\': " + name) }
    if name.starts_with(".") { return Err("'name' must not start with '.': " + name) }
    if name.starts_with("-") { return Err("'name' must not start with '-': " + name) }
    if name.contains("\n") || name.contains("\r") { return Err("'name' must not contain line breaks") }
    for c in ["*", "?", "[", "]", " ", "\t"] {
        if name.contains(c) { return Err("'name' must not contain '" + c + "': " + name) }
    }
    Ok(())
}

// sv_dir and service_dir: absolute, no `..` segments, one line.
fn require_dir(key: string, p: string) -> Result[unit, string] {
    if !p.starts_with("/") { return Err("'" + key + "' must be an absolute path: " + p) }
    for seg in p.split("/") {
        if seg == ".." { return Err("'" + key + "' must not contain '..' segments: " + p) }
    }
    if p.contains("\n") || p.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
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

fn mtime(p: string) -> int {
    match fs::metadata(p) {
        Ok(m) => {
            if let Some(v) = m.get("modified") { return v.as_int().unwrap_or(0) }
            0
        },
        Err(e) => 0,
    }
}
