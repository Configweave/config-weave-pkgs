use value
use json
use common
use vrange

fn validate(params: Value) -> Result[string, string] {
    let id = common::param_str(params, "id", "")
    common::validate_name("id", id)?
    vrange::validate("version", common::param_str(params, "version", ""))?
    common::single_line("source", common::param_str(params, "source", ""))?
    let e = ensure(params)?
    if e == "latest" && common::param_str(params, "version", "") != "" { return Err("'version' must be empty with ensure = :latest, which follows the newest version the source offers") }
    let scope = common::param_str(params, "scope", "any")
    if !["any", "user", "machine"].contains(scope) { return Err("invalid 'scope' value '" + scope + "' (expected :any, :user or :machine)") }
    let types = ["any", "msix", "msi", "appx", "exe", "zip", "inno", "nullsoft", "wix", "burn", "portable"]
    let t = common::param_str(params, "installer_type", "any")
    if !types.contains(t) { return Err("invalid 'installer_type' value '" + t + "'") }
    Ok(id)
}

fn ensure(params: Value) -> Result[string, string] {
    let e = common::param_str(params, "ensure", "present")
    if ["present", "latest", "absent"].contains(e) { return Ok(e) }
    Err("invalid 'ensure' value '" + e + "' (expected :present, :latest or :absent)")
}

fn scope(params: Value) -> string {
    let s = common::param_str(params, "scope", "any")
    if s == "any" { "" } else { s }
}

fn installer_type(params: Value) -> string {
    let t = common::param_str(params, "installer_type", "any")
    if t == "any" { "" } else { t }
}

// `winget list` filtered to the id (and the scope, and only packages with an
// upgrade, as asked). It exits 0x8A150014 when the package is not installed,
// but 0 with "No installed package found" when it is installed and the
// filter matches nothing (winget 1.6 and 1.29 alike), so a match also needs
// the id in the output. Ids are not localized; a long one the table cuts
// short ends in "…". None when winget is missing.
fn listed(params: Value, id: string, scope: string, upgrade: bool) -> Result[Option[bool], string] {
    let script = common::winget_ps() +
        "$a = @('list', '--exact', '--id', $env:CW_ID, '--accept-source-agreements', '--disable-interactivity')\n" +
        "if ([string]$env:CW_SCOPE -ne '') {{ $a += @('--scope', $env:CW_SCOPE) }}\n" +
        "if ([string]$env:CW_SOURCE -ne '') {{ $a += @('--source', $env:CW_SOURCE) }}\n" +
        "if ($env:CW_UPGRADE -eq '1') {{ $a += '--upgrade-available' }}\n" +
        "$o = @(& $winget @a)\n" +
        "$c = $LASTEXITCODE\n" +
        "if ($c -ne 0 -and $c -ne " + str(common::winget_none_found_code()) + ") {{ $o; exit $c }}\n" +
        "$id = [regex]::Escape($env:CW_ID)\n" +
        "$cut = [regex]::Escape($env:CW_ID.Substring(0, [Math]::Min(8, $env:CW_ID.Length)))\n" +
        "$hit = @($o | Where-Object {{ $_ -match ('(^|\\s)' + $id + '(\\s|$)') -or $_ -match ('(^|\\s)' + $cut + '\\S*' + [char]0x2026) }}).Count -gt 0\n" +
        "if ($c -eq 0 -and $hit) {{ exit 0 }}\n" +
        "exit " + str(common::winget_none_found_code()) + "\n"
    let out = common::query(script, #{
        "CW_ID": Value::String(id),
        "CW_SCOPE": Value::String(scope),
        "CW_SOURCE": Value::String(common::param_str(params, "source", "")),
        "CW_UPGRADE": Value::String(if upgrade { "1" } else { "0" })
    })?
    if out.code == common::missing_code() { return Ok(None) }
    if out.code == common::winget_none_found_code() { return Ok(Some(false)) }
    if !out.success { return Err(common::failure("winget list " + id, out)) }
    Ok(Some(true))
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
        "$v = ''; $done = $false\n" +
        // The module can be present yet unusable here (some of its cmdlets
        // refuse Windows PowerShell or SYSTEM); winget export is the fallback.
        "if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {{\n" +
        "  try {{ Import-Module Microsoft.WinGet.Client; foreach ($p in @(Get-WinGetPackage -Id $env:CW_ID -MatchOption Equals)) {{ if ($p.Id -ieq $env:CW_ID) {{ $v = [string]$p.InstalledVersion }} }}; $done = $true }} catch {{ $v = '' }}\n" +
        "}}\n" +
        "if (-not $done) {{\n" +
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
    let e = ensure(params)?
    let have = installed_version(params, id)?.unwrap_or("")
    if e == "absent" {
        if have != "" { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if have == "" { return Ok(CheckResult::NotConfigured) }
    if !vrange::satisfies("winget_package " + id, have, common::param_str(params, "version", ""), "winget's installed-package list (Microsoft.WinGet.Client or winget export)")? { return Ok(CheckResult::NotConfigured) }
    if scope(params) != "" && !listed(params, id, scope(params), false)?.unwrap_or(false) { return Ok(CheckResult::NotConfigured) }
    if e == "latest" && listed(params, id, "", true)?.unwrap_or(false) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

// Every version of `id` the source offers, newest first as winget prints
// them (winget show --versions). The table's header is localized, so the
// versions are the lines after its dashed rule.
fn available_versions(params: Value, id: string) -> Result[List[string], string] {
    let script = common::winget_ps() +
        "$a = @('show', '--id', $env:CW_ID, '--exact', '--versions', '--accept-source-agreements', '--disable-interactivity')\n" +
        "if ([string]$env:CW_SOURCE -ne '') {{ $a += @('--source', $env:CW_SOURCE) }}\n" +
        "$o = @(& $winget @a)\n" +
        "$c = $LASTEXITCODE\n" +
        "if ($c -ne 0) {{ $o; exit $c }}\n" +
        "$v = @(); $seen = $false\n" +
        "foreach ($l in $o) {{ $t = ([string]$l).Trim(); if ($seen) {{ if ($t -ne '') {{ $v += $t }} }} elseif ($t -match '^-{{3,}}$') {{ $seen = $true }} }}\n" +
        "ConvertTo-Json -Compress @{{ versions = $v }}\n"
    let out = common::query(script, #{
        "CW_ID": Value::String(id),
        "CW_SOURCE": Value::String(common::param_str(params, "source", ""))
    })?
    if out.code == common::missing_code() { return Err("winget is not installed or cannot start, so the versions of " + id + " cannot be listed") }
    if !out.success { return Err(common::failure("winget show --versions " + id, out)) }
    let found: List[string] = []
    if let Some(vs) = json::parse(out.stdout.trim())?.get("versions") {
        for v in vs.as_list().unwrap_or([]) {
            if let Some(t) = v.as_string() { found.push(t) }
        }
    }
    Ok(found)
}

// The version to pass to winget install --version: none for any version,
// an exact version (or a pin that is not range syntax) as written, and for
// any other range the newest version the source offers that satisfies it.
fn target_version(params: Value, id: string) -> Result[string, string] {
    let want = common::param_str(params, "version", "")
    if vrange::any(want) { return Ok("") }
    if vrange::exact(want) || vrange::opaque(want) { return Ok(want) }
    vrange::pick("winget_package " + id, available_versions(params, id)?, want, "winget show --versions")
}

// :latest upgrades an installed package in place (winget upgrade) and
// installs a missing one; :present installs, replacing an installed one at
// another version or in another scope with --force.
fn apply(params: Value) -> Result[ApplyResult, string] {
    let id = validate(params)?
    let e = ensure(params)?
    let have = installed_version(params, id)?.unwrap_or("")
    let verb = "install"
    if e == "absent" { verb = "uninstall" }
    if e == "latest" && have != "" && (scope(params) == "" || listed(params, id, scope(params), false)?.unwrap_or(false)) { verb = "upgrade" }
    let version = if e == "absent" { "" } else { target_version(params, id)? }
    let script = common::winget_ps() +
        "$a = @($env:CW_VERB, '--exact', '--id', $env:CW_ID, '--silent', '--accept-source-agreements', '--disable-interactivity')\n" +
        "if ($env:CW_VERB -ne 'uninstall') {{ $a += '--accept-package-agreements' }}\n" +
        "if ($env:CW_VERB -ne 'uninstall' -and [string]$env:CW_TYPE -ne '') {{ $a += @('--installer-type', $env:CW_TYPE) }}\n" +
        "if ([string]$env:CW_VERSION -ne '') {{ $a += @('--version', $env:CW_VERSION) }}\n" +
        "if ([string]$env:CW_SCOPE -ne '') {{ $a += @('--scope', $env:CW_SCOPE) }}\n" +
        // An installed package at another version or scope is replaced:
        // --force lets winget install over it, up or down.
        "if ($env:CW_FORCE -eq '1') {{ $a += '--force' }}\n" +
        "if ([string]$env:CW_SOURCE -ne '') {{ $a += @('--source', $env:CW_SOURCE) }}\n" +
        "& $winget @a\n" +
        "exit $LASTEXITCODE\n"
    let out = common::action(script, #{
        "CW_VERB": Value::String(verb),
        "CW_ID": Value::String(id),
        "CW_VERSION": Value::String(version),
        "CW_TYPE": Value::String(installer_type(params)),
        "CW_SCOPE": Value::String(scope(params)),
        "CW_FORCE": Value::String(if verb == "install" && have != "" { "1" } else { "0" }),
        "CW_SOURCE": Value::String(if e == "absent" { "" } else { common::param_str(params, "source", "") })
    })?
    if out.code == common::winget_reboot_code() { return Ok(ApplyResult::RebootRequired) }
    if out.success || (verb != "uninstall" && out.code == common::winget_no_upgrade_code()) { return Ok(ApplyResult::Success) }
    Err(common::failure("winget " + verb + " " + id, out))
}
