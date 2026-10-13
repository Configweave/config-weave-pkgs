use value
use shell
use log
use fs
use http
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
    if !out.success { return Err(out.stderr.trim()) }
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
    if !out.success {
        let detail = if out.stderr.trim() == "" { out.stdout.trim() } else { out.stderr.trim() }
        return Err(detail)
    }
    Ok(ApplyResult::Success)
}

fn install_msi(params: Value) -> Result[ApplyResult, string] {
    let source = common::param_str(params, "source", "")
    if source == "" { return Err("'source' is required when method is :msi") }
    let local = if source.starts_with("http://") || source.starts_with("https://") {
        let tmp = fs::temp_file()? + ".msi"
        log::info("downloading " + source)
        http::download(source, tmp, Value::Null)?
        tmp
    } else {
        if !fs::exists(source) { return Err("'source' does not exist: " + source) }
        source
    }
    log::info("installing the URL Rewrite module from " + local)
    run_installer(
        "$p = Start-Process msiexec.exe -ArgumentList @('/i', " + common::ps_q(local) +
        ", '/qn', '/norestart') -Wait -PassThru; exit $p.ExitCode")
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
