use value
use json
use common

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name("name", name)?
    let present = common::want_present(params)?
    let url = common::param_str(params, "url", "")
    common::single_line("url", url)?
    if present && url == "" { return Err("missing 'url' parameter (required when :present)") }
    Ok(name)
}

// The source as Chocolatey lists it ("name|url|disabled|..."), matched
// case-insensitively. None when Chocolatey is missing.
fn source(name: string) -> Result[Option[Value], string] {
    let script = common::choco_ps() +
        "$out = & $choco source list --limit-output\n" +
        "if ($LASTEXITCODE -ne 0) {{ $out; exit $LASTEXITCODE }}\n" +
        "$r = @{{ exists = $false; url = ''; disabled = $false }}\n" +
        "foreach ($line in $out) {{ $p = ([string]$line).Trim() -split '\\|'; if ($p.Count -ge 3 -and $p[0] -ieq $env:CW_NAME) {{ $r = @{{ exists = $true; url = $p[1]; disabled = ($p[2] -ieq 'true') }} }} }}\n" +
        "ConvertTo-Json -Compress $r\n"
    let out = common::query(script, #{ "CW_NAME": Value::String(name) })?
    if out.code == common::missing_code() { return Ok(None) }
    if !out.success { return Err(common::failure("choco source list", out)) }
    Ok(Some(json::parse(out.stdout.trim())?))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let s = source(name)?
    if !common::want_present(params)? {
        if let Some(m) = s { if common::get_bool(m, "exists") { return Ok(CheckResult::NotConfigured) } }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if s.is_none() { return Ok(CheckResult::NotConfigured) }
    let m = s.unwrap_or(Value::Null)
    if !common::get_bool(m, "exists") { return Ok(CheckResult::NotConfigured) }
    if common::get_str(m, "url") != common::param_str(params, "url", "") { return Ok(CheckResult::NotConfigured) }
    if common::get_bool(m, "disabled") == common::param_bool(params, "enabled", true) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn choco(args: string, name: string, url: string, what: string) -> Result[unit, string] {
    let script = common::choco_ps() + "& $choco " + args + "\nexit $LASTEXITCODE\n"
    let out = common::action(script, #{ "CW_NAME": Value::String(name), "CW_URL": Value::String(url) })?
    if !out.success { return Err(common::failure(what, out)) }
    Ok(())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let url = common::param_str(params, "url", "")
    if !common::want_present(params)? {
        choco("source remove \"--name=$env:CW_NAME\"", name, url, "choco source remove " + name)?
        return Ok(ApplyResult::Success)
    }
    let s = source(name)?
    if s.is_none() { return Err("choco source add " + name + " failed: Chocolatey is not installed (or not on PATH)") }
    let m = s.unwrap_or(Value::Null)
    // `source add` on an existing name replaces its URL in place.
    if !common::get_bool(m, "exists") || common::get_str(m, "url") != url {
        choco("source add \"--name=$env:CW_NAME\" \"--source=$env:CW_URL\"", name, url, "choco source add " + name)?
    }
    let enabled = common::param_bool(params, "enabled", true)
    let verb = if enabled { "enable" } else { "disable" }
    choco("source " + verb + " \"--name=$env:CW_NAME\"", name, url, "choco source " + verb + " " + name)?
    Ok(ApplyResult::Success)
}
