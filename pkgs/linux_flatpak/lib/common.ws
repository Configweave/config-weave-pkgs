use value
use shell

// Helpers shared by linux_flatpak's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

// A failed command's error: stderr, else stdout, always with the exit code.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

fn output(what: string, cmd: string) -> Result[CmdOutput, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(out)
}

fn run(what: string, cmd: string) -> Result[unit, string] {
    let out = output(what, cmd)?
    Ok(())
}

// A remote name or application id: letters, digits, '_', '-' and '.', not
// starting with '-' or '.', so it can be neither an option nor a ref with a
// branch (org.example.App//stable).
fn ident(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    if v.starts_with("-") || v.starts_with(".") || !v.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.') {
        return Err("invalid '" + key + "' '" + v + "': use letters, digits, '_', '-' and '.', not starting with '-' or '.'")
    }
    Ok(())
}

// The flatpak installation a resource works on: every flatpak command it
// runs is scoped with --system or --user, since unscoped listing commands
// span both while unscoped changes default to system.
fn scope(params: Value) -> Result[string, string] {
    let s = param_str(params, "installation", "system")
    if s == "system" || s == "user" { return Ok(s) }
    Err("invalid 'installation' value '" + s + "' (expected :system or :user)")
}

// flatpak against one installation. Never prompting: a question that would
// need an answer fails instead (stdin is closed, so a y/n prompt reads n).
fn flatpak(inst: string, args: string) -> string {
    "flatpak " + args + " --" + inst + " </dev/null"
}
