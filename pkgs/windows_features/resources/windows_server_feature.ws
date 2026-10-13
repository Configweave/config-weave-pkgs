use value
use json
use common

// Get-WindowsFeature exists only on Windows Server (the ServerManager
// module); client SKUs use windows_optional_feature instead.
fn server_only() -> string {
    "if (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {{ throw 'windows_server_feature needs Windows Server (the ServerManager module); on client Windows use windows_optional_feature' }}\n"
}

// The feature's InstallState, plus the management tools that are out of
// step with `ensure`: the -IncludeManagementTools variant of the -WhatIf
// install (or uninstall) lists more features than the plain one exactly when
// tools are missing (or still installed). Both lists come from
// ServerManager itself, so no table of which tools belong to which role is
// needed, and a deliberately removed sub-feature is not mistaken for a tool.
fn query(name: string, present: bool, tools: bool) -> Result[Value, string] {
    let script = server_only() +
        "$f = @(Get-WindowsFeature -Name $env:CW_NAME)\n" +
        "if ($f.Count -ne 1) {{ throw ('expected exactly one Windows feature named ' + $env:CW_NAME + ', found ' + $f.Count) }}\n" +
        "$extra = @()\n" +
        "if ($env:CW_TOOLS -eq '1') {{\n" +
        "  if ($env:CW_PRESENT -eq '1') {{\n" +
        "    $with = @((Install-WindowsFeature -Name $env:CW_NAME -IncludeManagementTools -WhatIf 6>$null).FeatureResult)\n" +
        "    $without = @((Install-WindowsFeature -Name $env:CW_NAME -WhatIf 6>$null).FeatureResult)\n" +
        "  }} else {{\n" +
        "    $with = @((Uninstall-WindowsFeature -Name $env:CW_NAME -IncludeManagementTools -WhatIf 6>$null).FeatureResult)\n" +
        "    $without = @((Uninstall-WindowsFeature -Name $env:CW_NAME -WhatIf 6>$null).FeatureResult)\n" +
        "  }}\n" +
        "  $plain = @($without | ForEach-Object {{ $_.Name }})\n" +
        "  $extra = @($with | ForEach-Object {{ $_.Name }} | Where-Object {{ $plain -notcontains $_ }})\n" +
        "}}\n" +
        "ConvertTo-Json -Compress @{{ state = $f[0].InstallState.ToString(); extra = [string]($extra -join ',') }}\n"
    let out = common::run_ps(script, #{
        "CW_NAME": Value::String(name),
        "CW_PRESENT": Value::String(if present { "1" } else { "0" }),
        "CW_TOOLS": Value::String(if tools { "1" } else { "0" })
    })?
    if !out.success { return Err(common::failure("reading Windows feature '" + name + "'", out)) }
    // -WhatIf writes its "What if:" lines straight to the host, ahead of the
    // JSON, so only the last line is the answer.
    let last = ""
    for line in out.stdout.split("\n") {
        if line.trim() != "" { last = line.trim() }
    }
    json::parse(last)
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name(name)?
    common::single_line("source", common::param_str(params, "source", ""))?
    common::want_present(params)?
    Ok(name)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let tools = common::param_bool(params, "include_management_tools", false)
    let q = query(name, present, tools)?
    let st = get_str(q, "state")
    let tools_ok = get_str(q, "extra") == ""
    if present {
        if st == "InstallPending" { return Ok(CheckResult::RebootRequired) }
        if st == "Installed" && tools_ok { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "UninstallPending" { return Ok(CheckResult::RebootRequired) }
    if (st == "Available" || st == "Removed") && tools_ok { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let cmdlet = if present {
        "$a = @{{ Name = $env:CW_NAME }}\n" +
        "if ([string]$env:CW_SOURCE -ne '') {{ $a.Source = $env:CW_SOURCE }}\n" +
        "if ($env:CW_TOOLS -eq '1') {{ $a.IncludeManagementTools = $true }}\n" +
        "$r = Install-WindowsFeature @a\n"
    } else {
        "$a = @{{ Name = $env:CW_NAME }}\n" +
        "if ($env:CW_TOOLS -eq '1') {{ $a.IncludeManagementTools = $true }}\n" +
        "$r = Uninstall-WindowsFeature @a\n"
    }
    // A failed install does not always throw: Success is false and ExitCode
    // says why (FailedRestartRequired, InvalidArgs, ...).
    let script = server_only() + cmdlet +
        "if (-not $r.Success) {{ throw ('ServerManager reported failure: ExitCode ' + $r.ExitCode) }}\n" +
        "if ([string]$r.RestartNeeded -eq 'Yes') {{ exit 3010 }}\n"
    let out = common::run_ps(script, #{
        "CW_NAME": Value::String(name),
        "CW_SOURCE": Value::String(common::param_str(params, "source", "")),
        "CW_TOOLS": Value::String(if common::param_bool(params, "include_management_tools", false) { "1" } else { "0" })
    })?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(common::failure((if present { "installing" } else { "removing" }) + " Windows feature '" + name + "'", out)) }
    Ok(ApplyResult::Success)
}
