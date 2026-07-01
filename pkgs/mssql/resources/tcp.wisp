use value
use fs
use shell
use sys
use registry
use service
use data
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

// --- Windows --------------------------------------------------------------

fn win_instance_id(instance_name: string) -> Result[string, string] {
    let key = "HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\Instance Names\\SQL"
    if let Some(v) = registry::read(key, instance_name)? {
        if let Some(s) = v.as_string() { return Ok(s) }
    }
    Err("SQL Server instance '" + instance_name + "' is not installed")
}

fn win_tcp_key(id: string) -> string {
    "HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\" + id + "\\MSSQLServer\\SuperSocketNetLib\\Tcp"
}

fn win_service_name(instance_name: string) -> string {
    if instance_name == "MSSQLSERVER" { "MSSQLSERVER" } else { "MSSQL$" + instance_name }
}

fn win_check(params: Value) -> Result[CheckResult, string] {
    let inst = param_str(params, "instance_name", "MSSQLSERVER")
    let port = param_int(params, "port", 1433)
    let want_enabled = if param_bool(params, "enabled", true) { 1 } else { 0 }
    let id = win_instance_id(inst)?
    let tcp = win_tcp_key(id)
    let ipall = tcp + "\\IPAll"

    let enabled_ok = if let Some(v) = registry::read(tcp, "Enabled")? {
        if let Some(i) = v.as_int() { i == want_enabled } else { false }
    } else { false }
    let port_ok = if let Some(v) = registry::read(ipall, "TcpPort")? {
        if let Some(s) = v.as_string() { s == str(port) } else { false }
    } else { false }

    if enabled_ok && port_ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn win_apply(params: Value) -> Result[ApplyResult, string] {
    let inst = param_str(params, "instance_name", "MSSQLSERVER")
    let port = param_int(params, "port", 1433)
    let want_enabled = if param_bool(params, "enabled", true) { 1 } else { 0 }
    let id = win_instance_id(inst)?
    let tcp = win_tcp_key(id)
    let ipall = tcp + "\\IPAll"

    registry::write(tcp, "Enabled", Value::Int(want_enabled), "dword")?
    registry::write(ipall, "TcpPort", Value::String(str(port)), "sz")?
    registry::write(ipall, "TcpDynamicPorts", Value::String(""), "sz")?

    if param_bool(params, "restart", true) {
        let svc = win_service_name(inst)
        log::info("restarting service " + svc + " to apply TCP settings")
        service::stop(svc)?
        service::start(svc)?
    }
    Ok(ApplyResult::Success)
}

// --- Linux ----------------------------------------------------------------

fn linux_port() -> Result[string, string] {
    if !fs::exists("/var/opt/mssql/mssql.conf") { return Ok("1433") }
    let cfg = fs::read("/var/opt/mssql/mssql.conf")?
    let parsed = data::ini_parse(cfg)?
    if let Some(net) = parsed.get("network") {
        if let Some(p) = net.get("tcpport") {
            if let Some(s) = p.as_string() { return Ok(s.trim()) }
        }
    }
    Ok("1433")
}

// mssql-conf has no switch to turn the TCP protocol off, so enabled=false is
// an error on Linux rather than a silently ignored parameter.
fn linux_check(params: Value) -> Result[CheckResult, string] {
    if !param_bool(params, "enabled", true) { return Err("'enabled = false' is not supported on Linux: mssql-conf cannot disable the TCP protocol") }
    let port = param_int(params, "port", 1433)
    if linux_port()? == str(port) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn linux_apply(params: Value) -> Result[ApplyResult, string] {
    if !param_bool(params, "enabled", true) { return Err("'enabled = false' is not supported on Linux: mssql-conf cannot disable the TCP protocol") }
    let port = param_int(params, "port", 1433)
    let set = shell::bash("/opt/mssql/bin/mssql-conf set network.tcpport " + str(port), Value::Null)?
    if !set.success { return Err("mssql-conf set tcpport failed: " + set.stderr.trim()) }
    if param_bool(params, "restart", true) {
        let r = shell::bash("systemctl restart mssql-server", Value::Null)?
        if !r.success { return Err("restarting mssql-server failed: " + r.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if sys::family() == "windows" { win_check(params) } else { linux_check(params) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if sys::family() == "windows" { win_apply(params) } else { linux_apply(params) }
}
