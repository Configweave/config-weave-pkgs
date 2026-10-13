use value
use json
use common

fn validate(params: Value) -> Result[string, string] {
    let id = common::param_str(params, "id", "")
    common::validate_name("id", id)?
    common::validate_version(common::param_str(params, "version", ""))?
    common::single_line("source", common::param_str(params, "source", ""))?
    common::want_present(params)?
    Ok(id)
}

// The installed version of `id` (matched case-insensitively, as winget
// does), or "" when it is not installed; None when winget is missing.
//
// The Microsoft.WinGet.Client module is used where it is installed;
// otherwise `winget export`, whose JSON carries exact ids and versions. The
// table `winget list` prints is never parsed: its headers are localized and
// its columns are truncated by display width.
fn installed_version(params: Value, id: string) -> Result[Option[string], string] {
    let script = common::winget_ps() +
        "$v = ''\n" +
        "if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {{\n" +
        "  Import-Module Microsoft.WinGet.Client\n" +
        "  foreach ($p in @(Get-WinGetPackage -Id $env:CW_ID -MatchOption Equals)) {{ if ($p.Id -ieq $env:CW_ID) {{ $v = [string]$p.InstalledVersion }} }}\n" +
        "}} else {{\n" +
        "  $f = Join-Path ([IO.Path]::GetTempPath()) ('cw-winget-' + [guid]::NewGuid().ToString() + '.json')\n" +
        "  $a = @('export', '--output', $f, '--include-versions', '--accept-source-agreements', '--disable-interactivity')\n" +
        "  if ([string]$env:CW_SOURCE -ne '') {{ $a += @('--source', $env:CW_SOURCE) }}\n" +
        "  $o = & $winget @a\n" +
        "  if (-not (Test-Path -LiteralPath $f)) {{ $o; exit $(if ($LASTEXITCODE) {{ $LASTEXITCODE }} else {{ 1 }}) }}\n" +
        "  $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json\n" +
        "  Remove-Item -LiteralPath $f -Force\n" +
        "  foreach ($s in @($j.Sources)) {{ foreach ($p in @($s.Packages)) {{ if ($p.PackageIdentifier -ieq $env:CW_ID) {{ $v = [string]$p.Version }} }} }}\n" +
        "}}\n" +
        "ConvertTo-Json -Compress @{{ version = $v }}\n"
    let out = common::query(script, #{
        "CW_ID": Value::String(id),
        "CW_SOURCE": Value::String(common::param_str(params, "source", ""))
    })?
    if out.code == common::missing_code() { return Ok(None) }
    if !out.success { return Err(common::failure("listing winget packages", out)) }
    // A package winget lists without a version reads as "Unknown"; it is
    // still installed.
    let v = common::get_str(json::parse(out.stdout.trim())?, "version")
    Ok(Some(v))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let id = validate(params)?
    let iv = installed_version(params, id)?
    let have = iv.unwrap_or("")
    if !common::want_present(params)? {
        if have != "" { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if have == "" { return Ok(CheckResult::NotConfigured) }
    let want = common::param_str(params, "version", "")
    if want != "" && have != want { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let id = validate(params)?
    let present = common::want_present(params)?
    let have = installed_version(params, id)?.unwrap_or("")
    let script = common::winget_ps() +
        "if ($env:CW_PRESENT -eq '1') {{\n" +
        "  $a = @('install', '--exact', '--id', $env:CW_ID, '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')\n" +
        "  if ([string]$env:CW_VERSION -ne '') {{ $a += @('--version', $env:CW_VERSION) }}\n" +
        // An installed package at another version is replaced: --force
        // lets winget install over it, up or down.
        "  if ($env:CW_FORCE -eq '1') {{ $a += '--force' }}\n" +
        "  if ([string]$env:CW_SOURCE -ne '') {{ $a += @('--source', $env:CW_SOURCE) }}\n" +
        "}} else {{\n" +
        "  $a = @('uninstall', '--exact', '--id', $env:CW_ID, '--silent', '--accept-source-agreements', '--disable-interactivity')\n" +
        "}}\n" +
        "& $winget @a\n" +
        "exit $LASTEXITCODE\n"
    let out = common::action(script, #{
        "CW_PRESENT": Value::String(if present { "1" } else { "0" }),
        "CW_ID": Value::String(id),
        "CW_VERSION": Value::String(common::param_str(params, "version", "")),
        "CW_FORCE": Value::String(if present && have != "" { "1" } else { "0" }),
        "CW_SOURCE": Value::String(common::param_str(params, "source", ""))
    })?
    if !out.success { return Err(common::failure("winget " + (if present { "install " } else { "uninstall " }) + id, out)) }
    Ok(ApplyResult::Success)
}
