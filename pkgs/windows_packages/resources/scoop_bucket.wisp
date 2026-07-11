use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn present(name: string) -> Result[bool, string] {
    let script = "$root = if ($env:SCOOP) {{ $env:SCOOP }} else {{ \"$env:USERPROFILE\\scoop\" }}; if (Test-Path \"$root\\buckets\\" + name + "\") {{ 'YES' }} else {{ 'NO' }}"
    Ok(shell::powershell(script, Value::Null)?.stdout.trim() == "YES")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if present(name)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let url = param_str(params, "url", "")
    if name == "" { return Err("missing 'name' parameter") }
    let uarg = if url != "" { " " + ps_q(url) } else { "" }
    let out = shell::powershell("scoop bucket add " + ps_q(name) + uarg + "; exit $LASTEXITCODE", Value::Null)?
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
