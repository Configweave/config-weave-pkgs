use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn installed(id: string) -> Result[bool, string] {
    let out = shell::powershell("winget list --exact --id " + ps_q(id) + " --accept-source-agreements 2>$null", Value::Null)?
    if !out.success { return Ok(false) }
    Ok(out.stdout.contains(id))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let id = param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    if installed(id)? { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let id = param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    let cmd = "winget uninstall --exact --id " + ps_q(id) + " --silent --accept-source-agreements; exit $LASTEXITCODE"
    let out = shell::powershell(cmd, Value::Null)?
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
