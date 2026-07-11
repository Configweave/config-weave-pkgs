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
    Err("invalid 'ensure' value '" + e + "' (expected \"present\" or \"absent\")")
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
    let present = want_present(params)?
    if installed(id)? == present { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let id = param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    let present = want_present(params)?
    let cmd = if present {
        let version = param_str(params, "version", "")
        let source = param_str(params, "source", "")
        let varg = if version != "" { " --version " + ps_q(version) } else { "" }
        let sarg = if source != "" { " --source " + ps_q(source) } else { "" }
        "winget install --exact --id " + ps_q(id) + varg + sarg + " --silent --accept-package-agreements --accept-source-agreements; exit $LASTEXITCODE"
    } else {
        "winget uninstall --exact --id " + ps_q(id) + " --silent --accept-source-agreements; exit $LASTEXITCODE"
    }
    let out = shell::powershell(cmd, Value::Null)?
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
