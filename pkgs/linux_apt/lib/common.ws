use value
use shell

// Helpers shared by linux_apt's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
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

// Values written into line-based files or protocols must stay on one line.
fn one_line(key: string, v: string) -> Result[unit, string] {
    if v.contains("\n") || v.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    Ok(())
}

// A package name or version handed to apt or dpkg as an operand: a leading
// '-' would be read as an option, and whitespace would split it in two.
fn operand(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    if v.starts_with("-") { return Err("'" + key + "' must not start with '-'") }
    if v.contains(" ") || v.contains("\t") || v.contains("\n") || v.contains("\r") {
        return Err("'" + key + "' must not contain whitespace")
    }
    Ok(())
}

// A basename joined onto an /etc/apt directory. apt only reads
// sources.list.d files named with letters, digits, '_', '-' and '.', so the
// same set keeps keyring names honest and rules out '/' and '..'.
fn file_name(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    if v.starts_with(".") || v.starts_with("-") || !v.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.') {
        return Err("invalid '" + key + "' '" + v + "': use letters, digits, '_', '-' and '.', not starting with '.' or '-'")
    }
    Ok(())
}

// apt-get as every resource runs it: never prompting, and waiting up to five
// minutes for the dpkg lock rather than failing at once when another apt
// process (or another linux_apt resource type running concurrently) holds it.
fn apt_get(args: string) -> string {
    "DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 " + args
}

// Packages apt-mark holds, one name per line.
fn held(name: string) -> Result[bool, string] {
    let out = output("apt-mark showhold", "apt-mark showhold")?
    for l in out.stdout.split("\n") {
        if l.trim() == name { return Ok(true) }
    }
    Ok(false)
}
