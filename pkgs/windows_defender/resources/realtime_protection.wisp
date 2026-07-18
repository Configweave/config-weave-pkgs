use value
use shell

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let want_disabled = if param_bool(params, "enabled", true) { "False" } else { "True" }
    let cur = ps_out("[string](Get-MpPreference).DisableRealtimeMonitoring")?
    if cur == want_disabled { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    // With Tamper Protection active this Set-MpPreference succeeds but the
    // effective state stays on; the re-check then reports the honest result.
    let arg = if param_bool(params, "enabled", true) { "$false" } else { "$true" }
    ps_run("Set-MpPreference -DisableRealtimeMonitoring " + arg)?
    Ok(ApplyResult::Success)
}
