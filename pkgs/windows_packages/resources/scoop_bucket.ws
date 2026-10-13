use value
use json
use common

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name("name", name)?
    common::single_line("url", common::param_str(params, "url", ""))?
    common::want_present(params)?
    Ok(name)
}

// Whether the bucket exists, and its git origin read straight from the
// clone's .git\config (no git needed for the check).
fn bucket(name: string) -> Result[Value, string] {
    let script = common::scoop_root_ps() +
        "$dir = Join-Path $scoopRoot ('buckets\\' + $env:CW_NAME)\n" +
        "$url = ''\n" +
        "$cfg = Join-Path $dir '.git\\config'\n" +
        "if (Test-Path -LiteralPath $cfg) {{\n" +
        "  $in = $false\n" +
        "  foreach ($line in Get-Content -LiteralPath $cfg) {{\n" +
        "    $t = $line.Trim()\n" +
        "    if ($t.StartsWith('[')) {{ $in = ($t -eq '[remote \"origin\"]') }}\n" +
        "    elseif ($in -and $t -match '^url\\s*=\\s*(.+)$') {{ $url = $Matches[1].Trim() }}\n" +
        "  }}\n" +
        "}}\n" +
        "ConvertTo-Json -Compress @{{ exists = (Test-Path -LiteralPath $dir); url = $url }}\n"
    let out = common::query(script, #{ "CW_NAME": Value::String(name) })?
    if !out.success { return Err(common::failure("probing scoop bucket " + name, out)) }
    json::parse(out.stdout.trim())
}

// Git URLs that name the same repository: case, a trailing slash and a
// trailing .git do not matter.
fn normal_url(url: string) -> string {
    let u = url.trim().to_lower()
    if u.ends_with("/") { u = u.slice(0, u.len() - 1) }
    if u.ends_with(".git") { u = u.slice(0, u.len() - 4) }
    u
}

fn url_drift(params: Value, b: Value) -> bool {
    let want = common::param_str(params, "url", "")
    want != "" && normal_url(common::get_str(b, "url")) != normal_url(want)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let b = bucket(name)?
    let exists = common::get_bool(b, "exists")
    if !common::want_present(params)? {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !exists || url_drift(params, b) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn scoop(args: string, name: string, url: string, what: string) -> Result[unit, string] {
    let script = common::scoop_ps() + "& $scoop " + args + "\nexit $LASTEXITCODE\n"
    let out = common::action(script, #{ "CW_NAME": Value::String(name), "CW_URL": Value::String(url) })?
    if !out.success { return Err(common::failure(what, out)) }
    Ok(())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let url = common::param_str(params, "url", "")
    let b = bucket(name)?
    let exists = common::get_bool(b, "exists")
    if !common::want_present(params)? {
        if exists { scoop("bucket rm $env:CW_NAME", name, url, "scoop bucket rm " + name)? }
        return Ok(ApplyResult::Success)
    }
    // A bucket pointing at another repository is removed and added again;
    // scoop has no "set url".
    if exists && url_drift(params, b) { scoop("bucket rm $env:CW_NAME", name, url, "scoop bucket rm " + name)? }
    if !exists || url_drift(params, b) {
        let args = if url != "" { "bucket add $env:CW_NAME $env:CW_URL" } else { "bucket add $env:CW_NAME" }
        scoop(args, name, url, "scoop bucket add " + name)?
    }
    Ok(ApplyResult::Success)
}
