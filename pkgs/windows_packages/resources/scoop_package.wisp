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

// A scoop app is installed when its current junction exists under the
// scoop root (per-user, so SCOOP env var wins, else ~\scoop).
fn installed(name: string) -> Result[bool, string] {
    let script = "$root = if ($env:SCOOP) {{ $env:SCOOP }} else {{ \"$env:USERPROFILE\\scoop\" }}; if (Test-Path \"$root\\apps\\" + name + "\\current\") {{ 'YES' }} else {{ 'NO' }}"
    Ok(shell::powershell(script, Value::Null)?.stdout.trim() == "YES")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if installed(name)? == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if want_present(params)? {
        "scoop install " + ps_q(name) + "; exit $LASTEXITCODE"
    } else {
        "scoop uninstall " + ps_q(name) + "; exit $LASTEXITCODE"
    }
    let out = shell::powershell(cmd, Value::Null)?
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
