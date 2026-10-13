use value
use fs
use shell
use sys
use registry
use data
use log
use common

// --- Windows --------------------------------------------------------------

fn win_tcp_key(params: Value) -> Result[string, string] {
    let inst = common::param_str(params, "instance", "MSSQLSERVER")
    let id = common::win_instance_id(inst)?
    if id == "" { return Err("SQL Server instance '" + inst + "' is not installed") }
    Ok("HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\" + id + "\\MSSQLServer\\SuperSocketNetLib\\Tcp")
}

fn reg_string(key: string, name: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, name)? {
        if let Some(s) = v.as_string() { return Ok(s.trim()) }
    }
    Ok("")
}

fn win_check(params: Value) -> Result[CheckResult, string] {
    let tcp = win_tcp_key(params)?
    let ipall = tcp + "\\IPAll"
    let want_enabled = if common::param_bool(params, "enabled", true) { 1 } else { 0 }
    let enabled_ok = if let Some(v) = registry::read(tcp, "Enabled")? {
        if let Some(i) = v.as_int() { i == want_enabled } else { false }
    } else { false }
    let port_ok = reg_string(ipall, "TcpPort")? == str(common::param_int(params, "port", 1433))
    // A dynamic port in IPAll wins over the static one once the engine restarts.
    let dynamic_ok = reg_string(ipall, "TcpDynamicPorts")? == ""
    if enabled_ok && port_ok && dynamic_ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn win_apply(params: Value) -> Result[ApplyResult, string] {
    let tcp = win_tcp_key(params)?
    let ipall = tcp + "\\IPAll"
    let want_enabled = if common::param_bool(params, "enabled", true) { 1 } else { 0 }
    registry::write(tcp, "Enabled", Value::Int(want_enabled), "dword")?
    registry::write(ipall, "TcpPort", Value::String(str(common::param_int(params, "port", 1433))), "sz")?
    registry::write(ipall, "TcpDynamicPorts", Value::String(""), "sz")?
    if common::param_bool(params, "restart", true) {
        let inst = common::param_str(params, "instance", "MSSQLSERVER")
        log::info("restarting " + common::win_service_name(inst) + " to apply TCP settings")
        common::win_restart_engine(inst)?
    } else {
        log::warn("TCP settings take effect when SQL Server restarts")
    }
    Ok(ApplyResult::Success)
}

// --- Linux ----------------------------------------------------------------

// The configured port, "1433" when unset. A config file that cannot be read
// or parsed counts as not configured rather than as an error.
fn linux_port() -> Option[string] {
    if !fs::exists("/var/opt/mssql/mssql.conf") { return Some("1433") }
    let Ok(cfg) = fs::read("/var/opt/mssql/mssql.conf") else { return None }
    let Ok(parsed) = data::ini_parse(cfg) else { return None }
    if let Some(net) = parsed.get("network") {
        if let Some(p) = net.get("tcpport") {
            if let Some(s) = p.as_string() { return Some(s.trim()) }
        }
    }
    Some("1433")
}

// mssql-conf has no switch to turn the TCP protocol off, so enabled=false is
// an error on Linux rather than a silently ignored parameter.
fn linux_check(params: Value) -> Result[CheckResult, string] {
    if !common::param_bool(params, "enabled", true) { return Err("'enabled = false' is not supported on Linux: mssql-conf cannot disable the TCP protocol") }
    let want = str(common::param_int(params, "port", 1433))
    if let Some(p) = linux_port() {
        if p == want { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn linux_apply(params: Value) -> Result[ApplyResult, string] {
    if !common::param_bool(params, "enabled", true) { return Err("'enabled = false' is not supported on Linux: mssql-conf cannot disable the TCP protocol") }
    let port = str(common::param_int(params, "port", 1433))
    let set = shell::bash("/opt/mssql/bin/mssql-conf set network.tcpport " + common::q(port), Value::Null)?
    if !set.success { return Err(common::cmd_error("mssql-conf set network.tcpport", set)) }
    if common::param_bool(params, "restart", true) {
        let r = shell::bash("systemctl restart mssql-server", Value::Null)?
        if !r.success { return Err(common::cmd_error("systemctl restart mssql-server", r)) }
    } else {
        log::warn("the new TCP port takes effect when mssql-server restarts")
    }
    Ok(ApplyResult::Success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if sys::family() == "windows" { win_check(params) } else { linux_check(params) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if sys::family() == "windows" { win_apply(params) } else { linux_apply(params) }
}
