use value
use shell

// Helpers shared by linux_apk's resources. Imported with `use common`;
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

// A failed command's error: stderr, else stdout (where apk reports most of
// what goes wrong), always with the exit code.
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

// Values written into line-based files must stay on one line.
fn one_line(key: string, v: string) -> Result[unit, string] {
    if v.contains("\n") || v.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    Ok(())
}

// A package spec handed to apk as an operand: a leading '-' would be read
// as an option, and whitespace would split it in two.
fn operand(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    if v.starts_with("-") { return Err("'" + key + "' must not start with '-'") }
    if v.contains(" ") || v.contains("\t") || v.contains("\n") || v.contains("\r") {
        return Err("'" + key + "' must not contain whitespace")
    }
    Ok(())
}

// apk as every resource runs it. apk takes an exclusive lock on its
// database and, by default, fails at once ("temporary error") when another
// apk holds it — which another linux_apk resource type may, running in the
// same play. --wait makes it wait up to five minutes instead.
fn apk(args: string) -> string { "apk --wait 300 " + args }

// cache_updated's stamp. Its mtime records the last refresh, and anything
// under sources() newer than it means the index is out of date.
fn stamp_path() -> string { "/var/lib/config-weave/apk-cache-updated" }

// Everything that changes what apk update fetches or trusts.
fn sources() -> string { "/etc/apk/repositories /etc/apk/repositories.d /etc/apk/keys" }

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

// A basename joined onto /etc/apk/keys. Alpine's own keys are named like
// alpine-devel@lists.alpinelinux.org-6165ee59, so '@' and '+' are allowed;
// '/' and '..' are not.
fn file_name(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    if v.starts_with(".") || v.starts_with("-") || !v.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == '@' || c == '+') {
        return Err("invalid '" + key + "' '" + v + "': use letters, digits, '_', '-', '.', '@' and '+', not starting with '.' or '-'")
    }
    Ok(())
}
