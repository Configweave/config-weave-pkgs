use value
use json
use common

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name("name", name)?
    let present = common::want_present(params)?
    let url = common::param_str(params, "url", "")
    common::single_line("url", url)?
    common::single_line("type", common::param_str(params, "type", ""))?
    if present && url == "" { return Err("missing 'url' parameter (required when :present)") }
    Ok(name)
}

// `winget source export -n <name>` prints the source as JSON (Name, Arg,
// Type, ...), and exits non-zero when there is no such source. None when
// winget is missing.
fn source(name: string) -> Result[Option[Value], string] {
    let script = common::winget_ps() +
        "$o = & $winget source export --name $env:CW_NAME --disable-interactivity\n" +
        "if ($LASTEXITCODE -ne 0) {{ ConvertTo-Json -Compress @{{ exists = $false }}; exit 0 }}\n" +
        "$j = ($o -join \"`n\") | ConvertFrom-Json\n" +
        "ConvertTo-Json -Compress @{{ exists = $true; arg = [string]$j.Arg; type = [string]$j.Type }}\n"
    let out = common::query(script, #{ "CW_NAME": Value::String(name) })?
    if out.code == common::missing_code() { return Ok(None) }
    if !out.success { return Err(common::failure("winget source export " + name, out)) }
    Ok(Some(json::parse(out.stdout.trim())?))
}

fn trim_slash(s: string) -> string {
    if s.ends_with("/") { return s.slice(0, s.len() - 1) }
    s
}

// The registered source differs from the params: another URL, or another
// type when one is asked for. Types compare case-insensitively, as winget
// treats them.
fn drift(params: Value, s: Value) -> bool {
    if trim_slash(common::get_str(s, "arg")) != trim_slash(common::param_str(params, "url", "")) { return true }
    let t = common::param_str(params, "type", "")
    t != "" && common::get_str(s, "type").to_lower() != t.to_lower()
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let s = source(name)?
    let exists = if let Some(m) = s { common::get_bool(m, "exists") } else { false }
    if !common::want_present(params)? {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !exists { return Ok(CheckResult::NotConfigured) }
    if drift(params, s.unwrap_or(Value::Null)) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn winget(script: string, params: Value, what: string) -> Result[unit, string] {
    let out = common::action(common::winget_ps() + script + "exit $LASTEXITCODE\n", #{
        "CW_NAME": Value::String(common::param_str(params, "name", "")),
        "CW_URL": Value::String(common::param_str(params, "url", "")),
        "CW_TYPE": Value::String(common::param_str(params, "type", ""))
    })?
    if !out.success { return Err(common::failure(what, out)) }
    Ok(())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let s = source(name)?
    if s.is_none() { return Err("winget is not installed (or not on PATH)") }
    let m = s.unwrap_or(Value::Null)
    let exists = common::get_bool(m, "exists")
    // `source remove` takes no agreement flags.
    let remove = "& $winget source remove --name $env:CW_NAME --disable-interactivity\n"
    if !common::want_present(params)? {
        if exists { winget(remove, params, "winget source remove " + name)? }
        return Ok(ApplyResult::Success)
    }
    // Only a source that differs is removed and added again; one that
    // already matches is left alone.
    if exists && drift(params, m) { winget(remove, params, "winget source remove " + name)? }
    if !exists || drift(params, m) {
        winget(
            "$a = @('source', 'add', '--name', $env:CW_NAME, '--arg', $env:CW_URL, '--accept-source-agreements', '--disable-interactivity')\n" +
            "if ([string]$env:CW_TYPE -ne '') {{ $a += @('--type', $env:CW_TYPE) }}\n" +
            "& $winget @a\n",
            params, "winget source add " + name)?
    }
    Ok(ApplyResult::Success)
}
