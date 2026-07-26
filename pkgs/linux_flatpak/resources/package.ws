use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn installed(id: string) -> Result[bool, string] {
    Ok(shell::bash("flatpak info " + q(id) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let id = param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    if installed(id)? == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let id = param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    let cmd = if want_present(params)? {
        let remote = param_str(params, "remote", "flathub")
        "flatpak install -y " + q(remote) + " " + q(id)
    } else {
        "flatpak uninstall -y " + q(id)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
