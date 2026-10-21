use value
use sys
use log
use fs
use shell
use registry
use common
use ssrs
use vrange

// Installs SQL Server Reporting Services 2017 and later, or Power BI Report
// Server, from the standalone installer (SQLServerReportingServices.exe,
// PowerBIReportServer.exe). SSRS 2016 and older is a SQL Server setup
// feature instead: mssql.instance with features = RS.

struct Want {
    product: string,
    svc: string,
    rs_name: string,
    edition: string,
    install_dir: string,
    version: string,
}

fn is_key(e: string) -> bool { e.contains("-") }

fn want(params: Value) -> Result[Want, string] {
    if sys::family() != "windows" { return Err("mssql.reporting_services is Windows only") }
    let product = common::param_str(params, "product", "ssrs")
    let info = ssrs::product_info(product)?
    let edition = common::param_str(params, "edition", "Dev")
    let ed_ok = ["dev", "eval", "expr"].contains(edition.to_lower()) || (is_key(edition) && common::only_chars(edition, "-") && edition.len() == 29)
    if !ed_ok { return Err("invalid 'edition' '" + edition + "' (Dev, Eval, Expr or a 25-character product key XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)") }
    if product == "pbirs" && edition.to_lower() == "expr" { return Err("Power BI Report Server has no Express edition (use Dev, Eval or a product key)") }
    let dir = common::param_str(params, "install_dir", "")
    common::no_newlines("install_dir", dir)?
    if dir.contains("\"") { return Err("'install_dir' must not contain a double quote") }
    let version = common::param_str(params, "version", "")
    vrange::validate("version", version)?
    Ok(Want { product: product, svc: info[0], rs_name: info[1], edition: edition, install_dir: dir, version: version })
}

// The installed product version and install folder (registry, under the id
// Instance Names\RS gives), and the edition (EditionName of the provider's
// MSReportServer_Instance, e.g. "SQL Server Developer"; the registry does not
// record it).
fn installed_facts(w: Want) -> Result[List[string], string] {
    let version = ssrs::reg_value(w.rs_name, "MSSQLServer\\CurrentVersion", "ProductVersion")?
    let dir = ssrs::reg_value(w.rs_name, "Setup", "InstallRootDirectory")?
    let edition = ssrs::edition(w.rs_name)?
    Ok([version, edition, dir])
}

fn edition_matches(want: string, have: string) -> bool {
    if is_key(want) { return true }
    let w = want.to_lower()
    let h = have.to_lower()
    if w == "dev" { return h.contains("developer") }
    if w == "eval" { return h.contains("evaluation") }
    if w == "expr" { return h.contains("express") }
    false
}

fn norm_dir(p: string) -> string {
    let t = p.trim().to_lower()
    if t.ends_with("\\") { t.slice(0, t.len() - 1) } else { t }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let w = want(params)?
    let present = ssrs::service_exists(w.svc)?
    if !common::want_present(params)? {
        return Ok(if present { CheckResult::NotConfigured } else { CheckResult::AlreadyConfigured })
    }
    if !present { return Ok(CheckResult::NotConfigured) }
    let f = installed_facts(w)?
    if w.install_dir != "" && f[2] != "" && !norm_dir(f[2]).starts_with(norm_dir(w.install_dir)) {
        return Err(w.svc + " is installed in '" + f[2] + "', not '" + w.install_dir + "'; the install folder only changes by uninstalling and reinstalling")
    }
    if !edition_matches(w.edition, f[1]) {
        log::info(w.svc + " is " + f[1] + ", want " + w.edition)
        return Ok(CheckResult::NotConfigured)
    }
    if !vrange::satisfies("reporting_services " + w.svc, f[0], w.version, "the ProductVersion under its MSSQLServer\\CurrentVersion key")? {
        log::info(w.svc + " is version " + f[0] + ", want " + w.version)
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

// Runs the installer with `args`. 3010 means it wants a reboot.
fn run_installer(params: Value, exe: string, args: string, what: string) -> Result[ApplyResult, string] {
    let log_dir = fs::temp_dir()?
    let log_file = log_dir + "\\install.log"
    let all = args + " /log \"" + log_file + "\""
    let script = "$c = (Start-Process -FilePath " + common::ps_q(exe) + " -ArgumentList " + common::ps_q(all) + " -Wait -PassThru).ExitCode; exit $c"
    let out = shell::powershell(script, Value::Map(#{ "timeout": Value::Int(common::param_int(params, "install_timeout", 3600)) }))
    // The installer logs its reason as an "e000: Error:" line, well before
    // the end of the log.
    let tail_ps = "if (Test-Path -LiteralPath " + common::ps_q(log_file) + ") {{ " +
        "$e = @(Select-String -LiteralPath " + common::ps_q(log_file) + " -Pattern '\\]e\\d+: (Error|UnexpectedError: (Bundle|setup))' | ForEach-Object {{ $_.Line }}); " +
        "if ($e.Count -gt 0) {{ $e }} else {{ Get-Content -LiteralPath " + common::ps_q(log_file) + " -Tail 10 }} }}"
    let tail = if let Ok(t) = shell::powershell(tail_ps, Value::Null) { t.stdout.trim() } else { "" }
    fs::delete_dir(log_dir).unwrap_or(())
    let o = out?
    if o.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !o.success { return Err(what + " failed (exit " + str(o.code) + "); its log says:\n" + tail) }
    Ok(ApplyResult::Success)
}

fn with_installer(params: Value, w: Want, args: string, what: string) -> Result[ApplyResult, string] {
    let src = common::require(params, "setup_path")?
    let name = if w.product == "pbirs" { "PowerBIReportServer.exe" } else { "SQLServerReportingServices.exe" }
    let got = common::local_installer(src, name, common::param_str(params, "setup_sha256", ""))?
    let r = run_installer(params, got[0], args, what)
    if got[1] != "" { fs::delete_dir(got[1]).unwrap_or(()) }
    r
}

// While another install's reboot is pending the installer installs nothing
// and exits 3010, or sometimes 0, so the outcome is judged by whether the
// service exists afterwards: missing with a reboot pending asks for the
// reboot, after which apply runs the installer again.
fn installed_or_reboot(w: Want, r: ApplyResult) -> Result[ApplyResult, string] {
    if ssrs::service_exists(w.svc)? { return Ok(r) }
    if r == ApplyResult::RebootRequired || reboot_pending()? {
        log::warn("a reboot is pending, so the installer did not install " + w.svc + "; apply again after the reboot")
        return Ok(ApplyResult::RebootRequired)
    }
    Err("the installer finished but service " + w.svc + " does not exist")
}

// The markers Windows and its installers leave while a reboot is pending.
fn reboot_pending() -> Result[bool, string] {
    if registry::read("HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager", "PendingFileRenameOperations")?.is_some() { return Ok(true) }
    if registry::key_exists("HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending")? { return Ok(true) }
    registry::key_exists("HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired")
}

// The uninstall command the installer registered, used when no setup_path is given.
fn registered_uninstaller(w: Want) -> Result[string, string] {
    let script = "$k = Get-ChildItem 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall', 'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall' -ErrorAction SilentlyContinue | " +
        "ForEach-Object {{ Get-ItemProperty $_.PSPath }} | Where-Object {{ $_.BundleCachePath -and $_.BundleCachePath -like " + common::ps_q("*\\" + (if w.product == "pbirs" { "PowerBIReportServer" } else { "SQLServerReportingServices" }) + ".exe") + " }} | Select-Object -First 1\n" +
        "if ($k) {{ $k.BundleCachePath }}"
    common::ps("finding the " + w.svc + " uninstaller", script)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    if !common::want_present(params)? {
        if !ssrs::service_exists(w.svc)? { return Ok(ApplyResult::Success) }
        log::info("uninstalling " + w.svc)
        if common::param_str(params, "setup_path", "") != "" {
            return with_installer(params, w, "/quiet /norestart /uninstall", "uninstalling " + w.svc)
        }
        let exe = registered_uninstaller(w)?
        if exe == "" { return Err("no registered uninstaller for " + w.svc + "; set 'setup_path'") }
        return run_installer(params, exe, "/quiet /norestart /uninstall", "uninstalling " + w.svc)
    }
    let ed = if is_key(w.edition) { "/PID=" + w.edition } else { "/Edition=" + w.edition }
    let dir = if w.install_dir != "" { " /InstallFolder=\"" + w.install_dir + "\"" } else { "" }
    let present = ssrs::service_exists(w.svc)?
    // On an installed server the same installer upgrades the version, and
    // EditionUpgrade changes the edition.
    let action = if present && !edition_matches(w.edition, installed_facts(w)?[1]) { " /EditionUpgrade" } else { "" }
    log::info((if present { "updating " } else { "installing " }) + w.svc)
    let r = with_installer(params, w, "/quiet /norestart /IAcceptLicenseTerms " + ed + dir + action, "the " + w.svc + " installer")?
    installed_or_reboot(w, r)
}
