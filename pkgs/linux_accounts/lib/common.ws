use value
use fs
use shell

// Helpers shared by linux_accounts' resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
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

fn run(what: string, cmd: string) -> Result[unit, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(())
}

// Values written into line-based files (passwd, sudoers) stay on one line.
fn one_line(key: string, v: string) -> Result[unit, string] {
    if v.contains("\n") || v.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    Ok(())
}

fn is_digits(s: string) -> bool { s != "" && s.chars().all(|c| c >= '0' && c <= '9') }

// A user or group name as shadow-utils accepts it: letters, digits, '_',
// '.' and '-', not starting with '-' (it would read as an option) or '.',
// optionally ending in '$' (Samba machine accounts), at most 32 characters.
// All-digit names are rejected because they read as ids.
fn valid_account(key: string, name: string) -> Result[unit, string] {
    if name == "" { return Err("missing '" + key + "' parameter") }
    let body = if name.ends_with("$") { name.slice(0, name.len() - 1) } else { name }
    let ok = body != "" && name.len() <= 32 && !body.starts_with("-") && !body.starts_with(".") && !is_digits(body) &&
        body.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-')
    if !ok { return Err("invalid '" + key + "' value '" + name + "': use letters, digits, '_', '.' and '-', not starting with '-' or '.'") }
    Ok(())
}

// The entry for `name` in a colon-separated local database (/etc/passwd,
// /etc/group). Only the local files are read: getent and id also see LDAP
// and SSSD accounts, which useradd/usermod/userdel cannot manage.
fn local_entry(db: string, name: string) -> Result[Option[List[string]], string] {
    if !fs::is_file(db) { return Ok(None) }
    for line in fs::read(db)?.split("\n") {
        let fields = line.split(":")
        if fields.len() >= 3 && fields.get(0).unwrap_or("") == name { return Ok(Some(fields)) }
    }
    Ok(None)
}

fn field(entry: List[string], i: int) -> string { entry.get(i).unwrap_or("") }
