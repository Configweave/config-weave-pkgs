use value
use json
use common

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name("name", name)?
    common::validate_version(common::param_str(params, "version", ""))?
    common::single_line("source", common::param_str(params, "source", ""))?
    common::want_present(params)?
    Ok(name)
}

// The installed version of `name`, compared case-insensitively as
// Chocolatey does, or "" when it is not installed. None when Chocolatey
// itself is missing.
fn installed_version(name: string) -> Result[Option[string], string] {
    let script = common::choco_ps() +
        "$out = & $choco list --limit-output --exact @chocoLocal $env:CW_NAME\n" +
        "if ($LASTEXITCODE -ne 0) {{ $out; exit $LASTEXITCODE }}\n" +
        "$v = ''\n" +
        "foreach ($line in $out) {{ $p = ([string]$line).Trim() -split '\\|'; if ($p.Count -ge 2 -and $p[0] -ieq $env:CW_NAME) {{ $v = $p[1] }} }}\n" +
        "ConvertTo-Json -Compress @{{ version = $v }}\n"
    let out = common::query(script, #{ "CW_NAME": Value::String(name) })?
    if out.code == common::missing_code() { return Ok(None) }
    if !out.success { return Err(common::failure("choco list " + name, out)) }
    let v = json::parse(out.stdout.trim())?
    Ok(Some(common::get_str(v, "version")))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let iv = installed_version(name)?
    if !common::want_present(params)? {
        // Without Chocolatey nothing can be installed through it.
        if iv.unwrap_or("") != "" { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let have = iv.unwrap_or("")
    if have == "" { return Ok(CheckResult::NotConfigured) }
    let want = common::param_str(params, "version", "")
    if want != "" && have != want { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let have = installed_version(name)?.unwrap_or("")
    // An installed package at the wrong version is moved with upgrade,
    // which (unlike install) can also go down with --allow-downgrade.
    let verb = if !present { "uninstall" } else if have != "" { "upgrade" } else { "install" }
    let script = common::choco_ps() +
        "$a = @($env:CW_VERB, $env:CW_NAME, '-y', '--no-progress')\n" +
        "if ($env:CW_VERB -ne 'uninstall') {{\n" +
        "  if ([string]$env:CW_VERSION -ne '') {{ $a += @('--version', $env:CW_VERSION, '--allow-downgrade') }}\n" +
        "  if ([string]$env:CW_SOURCE -ne '') {{ $a += @('--source', $env:CW_SOURCE) }}\n" +
        "}}\n" +
        "& $choco @a\n" +
        "exit $LASTEXITCODE\n"
    let out = common::action(script, #{
        "CW_VERB": Value::String(verb),
        "CW_NAME": Value::String(name),
        "CW_VERSION": Value::String(common::param_str(params, "version", "")),
        "CW_SOURCE": Value::String(common::param_str(params, "source", ""))
    })?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(common::failure("choco " + verb + " " + name, out)) }
    Ok(ApplyResult::Success)
}
