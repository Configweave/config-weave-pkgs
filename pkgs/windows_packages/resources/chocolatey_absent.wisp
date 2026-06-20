use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn installed(name: string) -> Result[bool, string] {
    let out = shell::powershell("choco list --exact --limit-output " + ps_q(name) + " 2>$null", Value::Null)?
    for line in out.stdout.split("\n") {
        if line.trim().starts_with(name + "|") { return Ok(true) }
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if installed(name)? { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let out = shell::powershell("choco uninstall " + ps_q(name) + " -y --no-progress; exit $LASTEXITCODE", Value::Null)?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
