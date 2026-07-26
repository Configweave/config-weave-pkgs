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

fn remote_exists(name: string) -> Result[bool, string] {
    // First column of `flatpak remotes` is the remote name.
    let cmd = "flatpak remotes 2>/dev/null | awk '{{print $1}}' | grep -Fxq " + q(name)
    Ok(shell::bash(cmd, Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if remote_exists(name)? == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if want_present(params)? {
        let url = param_str(params, "url", "")
        if url == "" { return Err("missing 'url' parameter") }
        "flatpak remote-add --if-not-exists " + q(name) + " " + q(url)
    } else {
        "flatpak remote-delete " + q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
