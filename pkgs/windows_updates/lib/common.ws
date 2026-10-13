// Helpers every windows_updates script shares: param access, the policy
// registry keys, and running PowerShell.
use value
use registry
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// The Windows Update policy keys, the ones the Group Policy settings write.
// Most settings live on WindowsUpdate; the Automatic Updates ones (and the
// UseWUServer switch) live on its AU subkey.
fn wu_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate" }
fn au_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" }

// None when the value is absent, so a wanted 0 never matches a missing value
// (an unset policy is "not configured", not 0).
fn reg_int(key: string, name: string) -> Result[Option[int], string] {
    if let Some(v) = registry::read(key, name)? {
        return Ok(v.as_int())
    }
    Ok(None)
}

fn reg_str(key: string, name: string) -> Result[Option[string], string] {
    if let Some(v) = registry::read(key, name)? {
        return Ok(v.as_string())
    }
    Ok(None)
}

// -1 is the unmanaged sentinel throughout: it matches anything.
fn int_matches(key: string, name: string, want: int) -> Result[bool, string] {
    if want == -1 { return Ok(true) }
    if let Some(have) = reg_int(key, name)? { return Ok(have == want) }
    Ok(false)
}

fn put_int(key: string, name: string, want: int) -> Result[unit, string] {
    if want == -1 { return Ok(()) }
    registry::create_key(key)?
    registry::write(key, name, Value::Int(want), "dword")?
    Ok(())
}

fn has_value(key: string, name: string) -> Result[bool, string] {
    if let Some(_) = registry::read(key, name)? { return Ok(true) }
    Ok(false)
}

// Deleting is guarded by a read: a value (or key) that is already gone is
// the state :absent wants, not an error.
fn delete_value(key: string, name: string) -> Result[unit, string] {
    if has_value(key, name)? { registry::delete_value(key, name)? }
    Ok(())
}

fn any_value(key: string, names: List[string]) -> Result[bool, string] {
    for n in names { if has_value(key, n)? { return Ok(true) } }
    Ok(false)
}

fn delete_values(key: string, names: List[string]) -> Result[unit, string] {
    for n in names { delete_value(key, n)? }
    Ok(())
}

// A PowerShell single-quoted literal. PowerShell also treats the curly
// quotes U+2018 to U+201B as single quotes, so they are doubled too.
fn ps_q(s: string) -> string {
    let out = s.replace("'", "''")
    for quote in ["\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"] {
        out = out.replace(quote, quote + quote)
    }
    "'" + out + "'"
}

// The error carries stderr, falls back to stdout, and names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

fn powershell(what: string, script: string) -> Result[string, string] {
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(failure(what, out)) }
    Ok(out.stdout.trim())
}
