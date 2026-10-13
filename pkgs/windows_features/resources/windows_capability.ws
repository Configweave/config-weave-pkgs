use value
use common

// The capability's state. The name must match exactly one capability:
// Get-WindowsCapability matches -Name as a wildcard pattern.
fn state(name: string) -> Result[string, string] {
    let script = "$c = @(Get-WindowsCapability -Online -Name $env:CW_NAME -ErrorAction SilentlyContinue)\n" +
        "if ($c.Count -ne 1) {{ throw ('expected exactly one capability named ' + $env:CW_NAME + ', found ' + $c.Count) }}\n" +
        "$c[0].State.ToString()\n"
    let out = common::run_ps(script, #{ "CW_NAME": Value::String(name) })?
    if !out.success { return Err(common::failure("reading capability '" + name + "'", out)) }
    Ok(out.stdout.trim())
}

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name(name)?
    common::single_line("source", common::param_str(params, "source", ""))?
    common::want_present(params)?
    Ok(name)
}

// InstallPending and UninstallPending mean the change is made but needs a
// reboot; reporting that (rather than "not configured") stops every run
// from adding or removing the capability again.
fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let st = state(name)?
    if common::want_present(params)? {
        if st == "Installed" { return Ok(CheckResult::AlreadyConfigured) }
        if st == "InstallPending" { return Ok(CheckResult::RebootRequired) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "NotPresent" || st == "Staged" || st == "Removed" { return Ok(CheckResult::AlreadyConfigured) }
    if st == "UninstallPending" { return Ok(CheckResult::RebootRequired) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let cmdlet = if present {
        "$a = @{{ Online = $true; Name = $env:CW_NAME }}\n" +
        "if ([string]$env:CW_SOURCE -ne '') {{ $a.Source = $env:CW_SOURCE }}\n" +
        "if ($env:CW_LIMIT -eq '1') {{ $a.LimitAccess = $true }}\n" +
        "$r = Add-WindowsCapability @a\n"
    } else {
        "$r = Remove-WindowsCapability -Online -Name $env:CW_NAME\n"
    }
    let out = common::run_ps(cmdlet + "if ($r.RestartNeeded) {{ exit 3010 }}\n", #{
        "CW_NAME": Value::String(name),
        "CW_SOURCE": Value::String(common::param_str(params, "source", "")),
        "CW_LIMIT": Value::String(if common::param_bool(params, "limit_access", false) { "1" } else { "0" })
    })?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(common::failure((if present { "adding" } else { "removing" }) + " capability '" + name + "'", out)) }
    Ok(ApplyResult::Success)
}
