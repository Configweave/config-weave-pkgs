use value
use common

// The feature's DISM state. The name must match exactly one feature: DISM
// matches -FeatureName as a wildcard pattern, and an unknown name is an
// error rather than "disabled".
fn state(name: string) -> Result[string, string] {
    let script = "$f = @(Get-WindowsOptionalFeature -Online -FeatureName $env:CW_NAME -ErrorAction SilentlyContinue)\n" +
        "if ($f.Count -ne 1) {{ throw ('expected exactly one optional feature named ' + $env:CW_NAME + ', found ' + $f.Count) }}\n" +
        "$f[0].State.ToString()\n"
    let out = common::run_ps(script, #{ "CW_NAME": Value::String(name) })?
    if !out.success { return Err(common::failure("reading optional feature '" + name + "'", out)) }
    Ok(out.stdout.trim())
}

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name(name)?
    common::single_line("source", common::param_str(params, "source", ""))?
    common::want_present(params)?
    Ok(name)
}

// EnablePending and DisablePending mean the change is made but needs a
// reboot, which is reported as such rather than as converged.
fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let st = state(name)?
    if common::want_present(params)? {
        if st == "Enabled" { return Ok(CheckResult::AlreadyConfigured) }
        if st == "EnablePending" { return Ok(CheckResult::RebootRequired) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "Disabled" || st == "DisabledWithPayloadRemoved" { return Ok(CheckResult::AlreadyConfigured) }
    if st == "DisablePending" { return Ok(CheckResult::RebootRequired) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let cmdlet = if present {
        "$a = @{{ Online = $true; All = $true; NoRestart = $true; FeatureName = $env:CW_NAME }}\n" +
        "if ([string]$env:CW_SOURCE -ne '') {{ $a.Source = $env:CW_SOURCE }}\n" +
        "if ($env:CW_LIMIT -eq '1') {{ $a.LimitAccess = $true }}\n" +
        "$r = Enable-WindowsOptionalFeature @a\n"
    } else {
        "$r = Disable-WindowsOptionalFeature -Online -NoRestart -FeatureName $env:CW_NAME\n"
    }
    let out = common::run_ps(cmdlet + "if ($r.RestartNeeded) {{ exit 3010 }}\n", #{
        "CW_NAME": Value::String(name),
        "CW_SOURCE": Value::String(common::param_str(params, "source", "")),
        "CW_LIMIT": Value::String(if common::param_bool(params, "limit_access", false) { "1" } else { "0" })
    })?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(common::failure((if present { "enabling" } else { "disabling" }) + " optional feature '" + name + "'", out)) }
    Ok(ApplyResult::Success)
}
