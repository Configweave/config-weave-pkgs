use value
use fs
use path
use http
use shell
use sys
use registry
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }
// setup.exe expects double-quoted values; single quotes become literal chars.
fn dq(s: string) -> string { "\"" + s.replace("\"", "") + "\"" }

// The Instance Names registry value is present once an instance is installed.
fn win_installed(instance_name: string) -> Result[bool, string] {
    let key = "HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\Instance Names\\SQL"
    if let Some(_v) = registry::read(key, instance_name)? { return Ok(true) }
    Ok(false)
}

// Linux: the engine binary exists AND mssql-conf setup has run (service is
// active or enabled). A package-only install leaves the binary but no engine.
fn linux_installed() -> Result[bool, string] {
    if !fs::exists("/opt/mssql/bin/sqlservr") { return Ok(false) }
    let out = shell::bash("systemctl is-active --quiet mssql-server || systemctl is-enabled --quiet mssql-server", Value::Null)?
    Ok(out.success)
}

fn linux_manager() -> string {
    if fs::exists("/usr/bin/apt-get") { return "apt" }
    if fs::exists("/usr/bin/dnf5") { return "dnf5" }
    if fs::exists("/usr/bin/dnf") { return "dnf" }
    if fs::exists("/usr/bin/yum") { return "yum" }
    if fs::exists("/usr/bin/zypper") { return "zypper" }
    "unknown"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let inst = param_str(params, "instance_name", "MSSQLSERVER")
    if sys::family() == "windows" {
        if win_installed(inst)? { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if linux_installed()? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

// --- Windows --------------------------------------------------------------

fn win_pid_arg(edition: string) -> string {
    if edition == "" || edition == "Developer" || edition == "Evaluation" || edition == "Express" {
        return ""
    }
    " /PID=" + dq(edition)
}

fn win_apply(params: Value) -> Result[ApplyResult, string] {
    let setup = param_str(params, "setup_path", "")
    if setup == "" { return Err("missing 'setup_path' parameter (path or URL of SQL Server setup.exe)") }
    let local = if setup.starts_with("http") {
        let f = path::join(fs::temp_dir()?, "sqlserver-setup.exe")
        http::download(setup, f, Value::Null)?
        f
    } else {
        setup
    }

    let cfg = param_str(params, "config_file", "")
    let inst = param_str(params, "instance_name", "MSSQLSERVER")
    let tcp = if param_bool(params, "tcp_enabled", true) { "1" } else { "0" }

    // A full ConfigurationFile.ini wins: pass it through and only add the EULA.
    let args = if cfg != "" {
        "/Q /IACCEPTSQLSERVERLICENSETERMS /ConfigurationFile=" + dq(cfg)
    } else {
        let sec = param_str(params, "security_mode", "Windows")
        let sa = param_str(params, "sa_password", "")
        let sec_arg = if sec == "SQL" {
            if sa == "" { return Err("security_mode=SQL requires an 'sa_password'") }
            " /SECURITYMODE=SQL /SAPWD=" + dq(sa)
        } else { "" }
        let coll = param_str(params, "collation", "")
        let coll_arg = if coll != "" { " /SQLCOLLATION=" + dq(coll) } else { "" }
        let dd = param_str(params, "data_dir", "")
        let dd_arg = if dd != "" { " /SQLUSERDBDIR=" + dq(dd) } else { "" }
        let ld = param_str(params, "log_dir", "")
        let ld_arg = if ld != "" { " /SQLUSERDBLOGDIR=" + dq(ld) } else { "" }
        let bd = param_str(params, "backup_dir", "")
        let bd_arg = if bd != "" { " /SQLBACKUPDIR=" + dq(bd) } else { "" }
        let extra = param_str(params, "extra_args", "")
        let extra_arg = if extra != "" { " " + extra } else { "" }
        "/Q /ACTION=Install /IACCEPTSQLSERVERLICENSETERMS" +
            win_pid_arg(param_str(params, "edition", "Developer")) +
            " /FEATURES=" + param_str(params, "features", "SQLENGINE") +
            " /INSTANCENAME=" + dq(inst) +
            " /SQLSYSADMINACCOUNTS=" + dq(param_str(params, "sql_sysadmin_accounts", "BUILTIN\\Administrators")) +
            " /TCPENABLED=" + tcp +
            " /UPDATEENABLED=0" +
            sec_arg + coll_arg + dd_arg + ld_arg + bd_arg + extra_arg
    }

    log::info("running SQL Server setup for instance " + inst)
    let script = "$c=(Start-Process -FilePath " + ps_q(local) + " -ArgumentList " + ps_q(args) + " -Wait -PassThru).ExitCode; exit $c"
    let opts = Value::Map(#{ "timeout": Value::Int(param_int(params, "install_timeout", 3600)) })
    let out = shell::powershell(script, opts)?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err("setup.exe exited " + str(out.code) + ": " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

// --- Linux ----------------------------------------------------------------

fn linux_add_repo(params: Value, m: string) -> Result[unit, string] {
    let version = param_str(params, "version", "2022")
    let repo = param_str(params, "repo_url", "")
    if m == "apt" {
        let list = if repo != "" { repo } else { "https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-" + version + ".list" }
        let script = "set -e; " +
            "curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg; " +
            "curl -fsSL " + list + " -o /etc/apt/sources.list.d/mssql-server.list; " +
            "apt-get update"
        let out = shell::bash(script, Value::Null)?
        if !out.success { return Err("adding apt repo failed: " + out.stderr.trim()) }
        return Ok(())
    }
    if m == "dnf5" || m == "dnf" || m == "yum" {
        let url = if repo != "" { repo } else { "https://packages.microsoft.com/config/rhel/9/mssql-server-" + version + ".repo" }
        let out = shell::bash("curl -fsSL " + url + " -o /etc/yum.repos.d/mssql-server.repo", Value::Null)?
        if !out.success { return Err("adding yum repo failed: " + out.stderr.trim()) }
        return Ok(())
    }
    if m == "zypper" {
        let url = if repo != "" { repo } else { "https://packages.microsoft.com/config/sles/15/mssql-server-" + version + ".repo" }
        let out = shell::bash("zypper --non-interactive addrepo -fc " + url + " mssql-server || true", Value::Null)?
        if !out.success { return Err("adding zypper repo failed: " + out.stderr.trim()) }
        return Ok(())
    }
    Err("unsupported Linux package manager for SQL Server install; set 'repo_url' and use apt/dnf/yum/zypper")
}

fn linux_install_pkg(m: string) -> Result[unit, string] {
    let cmd = if m == "apt" {
        "ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive apt-get install -y mssql-server"
    } else if m == "dnf5" {
        "ACCEPT_EULA=Y dnf5 install -y mssql-server"
    } else if m == "dnf" {
        "ACCEPT_EULA=Y dnf install -y mssql-server"
    } else if m == "yum" {
        "ACCEPT_EULA=Y yum install -y mssql-server"
    } else if m == "zypper" {
        "ACCEPT_EULA=Y zypper --non-interactive install mssql-server"
    } else {
        return Err("unsupported Linux package manager")
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err("installing mssql-server failed: " + out.stderr.trim()) }
    Ok(())
}

fn linux_apply(params: Value) -> Result[ApplyResult, string] {
    let sa = param_str(params, "sa_password", "")
    if sa == "" { return Err("the Linux engine requires an 'sa_password'") }
    let m = linux_manager()
    if m == "unknown" { return Err("could not detect a supported Linux package manager") }

    if !fs::exists("/opt/mssql/bin/sqlservr") {
        linux_add_repo(params, m)?
        linux_install_pkg(m)?
    }

    let env = Value::Map(#{ "env": Value::Map(#{
        "ACCEPT_EULA": Value::String("Y"),
        "MSSQL_PID": Value::String(param_str(params, "edition", "Developer")),
        "MSSQL_SA_PASSWORD": Value::String(sa)
    }), "timeout": Value::Int(param_int(params, "install_timeout", 3600)) })
    log::info("running mssql-conf setup")
    let setup = shell::bash("/opt/mssql/bin/mssql-conf -n setup", env)?
    if !setup.success { return Err("mssql-conf setup failed: " + setup.stderr.trim()) }

    let coll = param_str(params, "collation", "")
    if coll != "" {
        let c = shell::bash("/opt/mssql/bin/mssql-conf set sqlserver.collation " + coll, Value::Null)?
        if !c.success { return Err("setting collation failed: " + c.stderr.trim()) }
    }

    let svc = shell::bash("systemctl enable --now mssql-server", Value::Null)?
    if !svc.success { return Err("enabling mssql-server failed: " + svc.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if sys::family() == "windows" { win_apply(params) } else { linux_apply(params) }
}
