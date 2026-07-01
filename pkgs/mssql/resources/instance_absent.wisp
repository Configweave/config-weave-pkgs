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

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }
// setup.exe expects double-quoted values and has no escape for an embedded
// double quote, so such values are rejected rather than silently mangled.
fn dq(s: string) -> Result[string, string] {
    if s.contains("\"") { return Err("a setup.exe argument value contains a double quote, which cannot be escaped") }
    Ok("\"" + s + "\"")
}

fn win_installed(instance_name: string) -> Result[bool, string] {
    let key = "HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\Instance Names\\SQL"
    if let Some(_v) = registry::read(key, instance_name)? { return Ok(true) }
    Ok(false)
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
    let inst = param_str(params, "instance", "MSSQLSERVER")
    if sys::family() == "windows" {
        if win_installed(inst)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if fs::exists("/opt/mssql/bin/sqlservr") { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
}

fn win_apply(params: Value) -> Result[ApplyResult, string] {
    let setup = param_str(params, "setup_path", "")
    if setup == "" { return Err("missing 'setup_path' parameter (path or URL of setup.exe for uninstall)") }
    let local = if setup.starts_with("http") {
        let f = path::join(fs::temp_dir()?, "sqlserver-setup.exe")
        http::download(setup, f, Value::Null)?
        f
    } else {
        setup
    }
    let inst = param_str(params, "instance", "MSSQLSERVER")
    let features = param_str(params, "features", "")
    let feat_arg = if features != "" { features } else { "SQLENGINE" }
    let args = "/Q /ACTION=Uninstall /INSTANCENAME=" + dq(inst)? + " /FEATURES=" + feat_arg
    log::info("uninstalling SQL Server instance " + inst)
    let script = "$c=(Start-Process -FilePath " + ps_q(local) + " -ArgumentList " + ps_q(args) + " -Wait -PassThru).ExitCode; exit $c"
    let opts = Value::Map(#{ "timeout": Value::Int(param_int(params, "install_timeout", 3600)) })
    let out = shell::powershell(script, opts)?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err("uninstall exited " + str(out.code) + ": " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn linux_apply(params: Value) -> Result[ApplyResult, string] {
    let m = linux_manager()
    let cmd = if m == "apt" {
        "DEBIAN_FRONTEND=noninteractive apt-get remove -y mssql-server"
    } else if m == "dnf5" {
        "dnf5 remove -y mssql-server"
    } else if m == "dnf" {
        "dnf remove -y mssql-server"
    } else if m == "yum" {
        "yum remove -y mssql-server"
    } else if m == "zypper" {
        "zypper --non-interactive remove mssql-server"
    } else {
        return Err("unsupported Linux package manager")
    }
    log::info("removing mssql-server package")
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err("removing mssql-server failed: " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if sys::family() == "windows" { win_apply(params) } else { linux_apply(params) }
}
