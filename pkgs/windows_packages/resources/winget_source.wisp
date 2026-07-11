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

// `winget source list --name <name>` exits non-zero when the source is absent.
fn source_present(name: string) -> Result[bool, string] {
    let out = shell::powershell("winget source list --name " + ps_q(name) + " 2>$null", Value::Null)?
    Ok(out.success)
}

// Match the configured URL literally rather than parsing winget's localized
// field labels (same idiom as winget_package's `installed`).
fn source_has_url(name: string, url: string) -> Result[bool, string] {
    let out = shell::powershell("winget source list --name " + ps_q(name) + " 2>$null", Value::Null)?
    if !out.success { return Ok(false) }
    Ok(out.stdout.contains(url))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let present = want_present(params)?
    if present {
        let url = param_str(params, "url", "")
        if url == "" { return Err("missing 'url' parameter") }
        if source_has_url(name, url)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
    } else {
        if source_present(name)? { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let present = want_present(params)?
    let cmd = if present {
        let url = param_str(params, "url", "")
        if url == "" { return Err("missing 'url' parameter") }
        let stype = param_str(params, "type", "")
        let targ = if stype != "" { " --type " + ps_q(stype) } else { "" }
        // remove first so a changed URL converges; ignore remove failure when absent
        "winget source remove --name " + ps_q(name) + " 2>$null; winget source add --name " + ps_q(name) + " --arg " + ps_q(url) + targ + " --accept-source-agreements; exit $LASTEXITCODE"
    } else {
        "winget source remove --name " + ps_q(name) + " --accept-source-agreements; exit $LASTEXITCODE"
    }
    let out = shell::powershell(cmd, Value::Null)?
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
