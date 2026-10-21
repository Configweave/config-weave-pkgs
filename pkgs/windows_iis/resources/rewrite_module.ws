use value
use shell
use log
use fs
use http
use hash
use common

// ---------------------------------------------------------------------------
// The IIS URL Rewrite module.
//
// URL Rewrite is not part of the IIS role: it is a separate MSI, which is why
// none of the rewrite resources can assume it. Detection is the same for all
// three install methods — the module drops rewrite.dll into inetsrv — so a
// module installed by hand, by Chocolatey or by an image build is recognised
// whichever method this step names.
//
// :msi is the default because it is the only method that works from a service
// or a scheduled task: winget is a per-user package manager, absent on Server
// SKUs and unavailable to SYSTEM, and Chocolatey has to be bootstrapped
// first.
// ---------------------------------------------------------------------------

fn installed() -> Result[bool, string] {
    // Resolved from %windir% rather than assumed to be on C:.
    let out = shell::powershell(
        "$p = Join-Path $env:windir 'system32\\inetsrv\\rewrite.dll'; " +
        "if (Test-Path $p) {{ 'YES' }} else {{ 'NO' }}", Value::Null)?
    if !out.success { return Err(common::failure(out)) }
    Ok(out.stdout.trim() == "YES")
}

fn method(params: Value) -> Result[string, string] {
    let m = common::param_str(params, "method", "msi")
    if m == "msi" || m == "winget" || m == "chocolatey" { return Ok(m) }
    Err("invalid 'method' value '" + m + "' (expected :msi, :winget or :chocolatey)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    method(params)?
    if installed()? == common::want_present(params)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

// msiexec's 3010 and 1641 both mean "done, reboot to finish".
fn run_installer(script: string) -> Result[ApplyResult, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(common::failure(out)) }
    Ok(ApplyResult::Success)
}

// An MSI runs as SYSTEM, so where it came from matters. Plain http is refused
// unless the step pins the file with sha256. With sha256 the file must match
// it; without, it must carry a valid Authenticode signature from Microsoft,
// which the published package and any byte-for-byte mirror of it do.
fn verify_msi(params: Value, local: string) -> Result[unit, string] {
    let want = common::param_str(params, "sha256", "").to_lower()
    if want != "" {
        let got = hash::sha256_file(local)?.to_lower()
        if got != want { return Err("sha256 of the MSI is " + got + ", expected " + want) }
        return Ok(())
    }
    let sig = common::ps_out("$s = Get-AuthenticodeSignature -LiteralPath " + common::ps_q(local) + "; " +
        "[string]$s.Status + '|' + [string]$s.SignerCertificate.Subject")?
    let parts = sig.split("|")
    if parts.get(0).unwrap_or("") != "Valid" {
        return Err("the MSI's Authenticode signature is " + parts.get(0).unwrap_or("") + "; give 'sha256' to install an unsigned package")
    }
    if !parts.get(1).unwrap_or("").contains("O=Microsoft Corporation") {
        return Err("the MSI is signed by " + parts.get(1).unwrap_or("") + ", not Microsoft; give 'sha256' to install it anyway")
    }
    Ok(())
}

fn install_msi(params: Value) -> Result[ApplyResult, string] {
    let source = common::param_str(params, "source", "")
    if source == "" { return Err("'source' is required when method is :msi") }
    let remote = source.starts_with("http://") || source.starts_with("https://")
    if source.starts_with("http://") && common::param_str(params, "sha256", "") == "" {
        return Err("'source' is plain http; use https or give 'sha256' to pin the file")
    }
    if !remote {
        if !fs::exists(source) { return Err("'source' does not exist: " + source) }
        verify_msi(params, source)?
        return run_msi(source)
    }
    // msiexec wants the .msi extension, so the download goes beside the
    // temp file rather than into it; both are deleted however the install
    // ends.
    let tmp = fs::temp_file()?
    let local = tmp + ".msi"
    log::info("downloading " + source)
    let result = download_and_run(params, source, local)
    fs::delete(local).unwrap_or(())
    fs::delete(tmp).unwrap_or(())
    result
}

// http::download checks a given `sha256` itself; without one the MSI's
// signature is checked as for a local file.
fn download_and_run(params: Value, source: string, local: string) -> Result[ApplyResult, string] {
    let want = common::param_str(params, "sha256", "")
    let o = #{ "retries": Value::Int(3) }
    if want != "" { o.insert("sha256", Value::String(want)) }
    http::download(source, local, Value::Map(o))?
    if want == "" { verify_msi(params, local)? }
    run_msi(local)
}

fn run_msi(local: string) -> Result[ApplyResult, string] {
    log::info("installing the URL Rewrite module from " + local)
    run_installer(
        "$p = Start-Process msiexec.exe -ArgumentList @('/i', ('\"' + " + common::ps_q(local) +
        " + '\"'), '/qn', '/norestart') -Wait -PassThru; exit $p.ExitCode")
}

fn uninstall_msi() -> Result[ApplyResult, string] {
    log::info("uninstalling the URL Rewrite module")
    // The product is registered under its display name rather than a stable
    // ProductCode across the 2.0 and 2.1 packages, so the code is looked up —
    // and an MSI subkey's own name IS the ProductCode.
    //
    // Both registry views are searched: a 32-bit package registers under
    // WOW6432Node on a 64-bit OS, and searching only the native view meant an
    // x86 install was never found. When nothing matches this now FAILS rather
    // than exiting 0 — the old behaviour reported success while rewrite.dll was
    // still on disk, so the step could never converge and never said why.
    run_installer(
        "$hives = @('HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall', " +
        "'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall'); " +
        "$k = $hives | Where-Object {{ Test-Path $_ }} | " +
        "ForEach-Object {{ Get-ChildItem $_ -ErrorAction SilentlyContinue }} | " +
        "ForEach-Object {{ Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue }} | " +
        "Where-Object {{ $_.DisplayName -like 'IIS URL Rewrite Module*' }} | " +
        "Sort-Object DisplayVersion -Descending | Select-Object -First 1; " +
        "if ($null -eq $k) {{ " +
        "Write-Error 'the URL Rewrite module is installed but has no uninstall entry in either " +
        "registry view; remove it by hand or with its own installer'; exit 1 }}; " +
        "$p = Start-Process msiexec.exe -ArgumentList @('/x', $k.PSChildName, '/qn', '/norestart') " +
        "-Wait -PassThru; exit $p.ExitCode")
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let how = method(params)?
    if !common::want_present(params)? {
        if !installed()? { return Ok(ApplyResult::Success) }
        if how == "winget" {
            return run_installer("winget uninstall -e --id Microsoft.IIS.URLRewrite " +
                "--silent --accept-source-agreements")
        }
        if how == "chocolatey" { return run_installer("choco uninstall urlrewrite -y") }
        return uninstall_msi()
    }
    if installed()? { return Ok(ApplyResult::Success) }
    if how == "winget" {
        log::info("installing the URL Rewrite module with winget")
        return run_installer("winget install -e --id Microsoft.IIS.URLRewrite " +
            "--silent --accept-package-agreements --accept-source-agreements")
    }
    if how == "chocolatey" {
        log::info("installing the URL Rewrite module with Chocolatey")
        return run_installer("choco install urlrewrite -y --no-progress")
    }
    install_msi(params)
}
