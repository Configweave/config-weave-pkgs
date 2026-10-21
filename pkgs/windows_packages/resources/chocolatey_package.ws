use value
use json
use common
use vrange

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name("name", name)?
    vrange::validate("version", common::param_str(params, "version", ""))?
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
    if !vrange::satisfies("chocolatey_package " + name, have, common::param_str(params, "version", ""), "choco list --exact " + name)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

// Every version of `name` the sources offer (choco search --exact
// --all-versions, which `search` means on Chocolatey 1.x and 2.x alike).
fn available_versions(params: Value, name: string) -> Result[List[string], string] {
    let script = common::choco_ps() +
        "$a = @('search', $env:CW_NAME, '--exact', '--all-versions', '--limit-output')\n" +
        "if ([string]$env:CW_SOURCE -ne '') {{ $a += @('--source', $env:CW_SOURCE) }}\n" +
        "$out = & $choco @a\n" +
        "if ($LASTEXITCODE -ne 0) {{ $out; exit $LASTEXITCODE }}\n" +
        "$v = @()\n" +
        "foreach ($line in $out) {{ $p = ([string]$line).Trim() -split '\\|'; if ($p.Count -ge 2 -and $p[0] -ieq $env:CW_NAME) {{ $v += $p[1] }} }}\n" +
        "ConvertTo-Json -Compress @{{ versions = $v }}\n"
    let out = common::query(script, #{
        "CW_NAME": Value::String(name),
        "CW_SOURCE": Value::String(common::param_str(params, "source", ""))
    })?
    if out.code == common::missing_code() { return Err("Chocolatey is not installed, so the versions of " + name + " cannot be listed") }
    if !out.success { return Err(common::failure("choco search --all-versions " + name, out)) }
    let found: List[string] = []
    if let Some(vs) = json::parse(out.stdout.trim())?.get("versions") {
        for v in vs.as_list().unwrap_or([]) {
            if let Some(t) = v.as_string() { found.push(t) }
        }
    }
    Ok(found)
}

// The version to pass to --version: none for any version, an exact
// version (or a pin that is not range syntax) as written, and for any other
// range the newest version the sources offer that satisfies it.
fn target_version(params: Value, name: string) -> Result[string, string] {
    let want = common::param_str(params, "version", "")
    if vrange::any(want) { return Ok("") }
    if vrange::exact(want) || vrange::opaque(want) { return Ok(want) }
    vrange::pick("chocolatey_package " + name, available_versions(params, name)?, want, "choco search --all-versions")
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let have = installed_version(name)?.unwrap_or("")
    // An installed package at the wrong version is moved with upgrade,
    // which (unlike install) can also go down with --allow-downgrade.
    let verb = if !present { "uninstall" } else if have != "" { "upgrade" } else { "install" }
    let version = if present { target_version(params, name)? } else { "" }
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
        "CW_VERSION": Value::String(version),
        "CW_SOURCE": Value::String(common::param_str(params, "source", ""))
    })?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(common::failure("choco " + verb + " " + name, out)) }
    Ok(ApplyResult::Success)
}
