use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// winget exits 0 even when nothing matches, printing a "no installed
// package" notice; treat the id appearing in the listing as installed.
fn installed(id: string) -> Result[bool, string] {
    let out = shell::powershell("winget list --exact --id " + ps_q(id) + " --accept-source-agreements 2>$null", Value::Null)?
    if !out.success { return Ok(false) }
    Ok(out.stdout.contains(id))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let id = param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    if installed(id)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let id = param_str(params, "id", "")
    let version = param_str(params, "version", "")
    let source = param_str(params, "source", "")
    if id == "" { return Err("missing 'id' parameter") }
    let varg = if version != "" { " --version " + ps_q(version) } else { "" }
    let sarg = if source != "" { " --source " + ps_q(source) } else { "" }
    let cmd = "winget install --exact --id " + ps_q(id) + varg + sarg + " --silent --accept-package-agreements --accept-source-agreements; exit $LASTEXITCODE"
    let out = shell::powershell(cmd, Value::Null)?
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
