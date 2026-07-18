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

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn state(name: string) -> Result[string, string] {
    let script = "$ErrorActionPreference='Stop'; (Get-WindowsCapability -Online -Name " + ps_q(name) + ").State"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let installed = state(name)? == "Installed"
    if installed == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let cmdlet = if want_present(params)? {
        "Add-WindowsCapability -Online -Name " + ps_q(name)
    } else {
        "Remove-WindowsCapability -Online -Name " + ps_q(name)
    }
    let script = "$ErrorActionPreference='Stop'; $r = " + cmdlet + "; if ($r.RestartNeeded) {{ exit 3010 }} else {{ exit 0 }}"
    let out = shell::powershell(script, Value::Null)?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
