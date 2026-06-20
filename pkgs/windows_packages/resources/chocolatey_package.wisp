use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// Installed version of `name` per `choco list`, or "" when not installed.
// `choco list --exact --limit-output` prints "name|version" lines.
fn installed_version(name: string) -> Result[string, string] {
    let out = shell::powershell("choco list --exact --limit-output " + ps_q(name) + " 2>$null", Value::Null)?
    for line in out.stdout.split("\n") {
        let t = line.trim()
        if t.starts_with(name + "|") { return Ok(t.slice(name.len() + 1, t.len())) }
    }
    Ok("")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    if name == "" { return Err("missing 'name' parameter") }
    let iv = installed_version(name)?
    if iv == "" { return Ok(CheckResult::NotConfigured) }
    if version != "" && iv != version { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    let source = param_str(params, "source", "")
    if name == "" { return Err("missing 'name' parameter") }
    let varg = if version != "" { " --version=" + ps_q(version) } else { "" }
    let sarg = if source != "" { " --source=" + ps_q(source) } else { "" }
    let out = shell::powershell("choco install " + ps_q(name) + " -y --no-progress" + varg + sarg + "; exit $LASTEXITCODE", Value::Null)?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
