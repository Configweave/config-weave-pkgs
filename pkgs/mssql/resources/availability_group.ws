use value
use shell
use sys
use registry
use log
use common

fn cluster_type(params: Value) -> Result[string, string] {
    let c = common::param_str(params, "cluster_type", "none")
    if c == "none" { return Ok("NONE") }
    if c == "wsfc" { return Ok("WSFC") }
    if c == "external" { return Ok("EXTERNAL") }
    Err("invalid 'cluster_type' value '" + c + "' (expected :none, :wsfc or :external)")
}

fn hadr_enabled(params: Value) -> Result[bool, string] {
    Ok(common::run_scalar(params, "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int);")? == "1")
}

// Enables HADR, which restarts the engine, and waits for it to come back.
fn enable_hadr(params: Value) -> Result[unit, string] {
    let inst = common::param_str(params, "instance", "")
    common::check_instance(inst)?
    if sys::family() == "windows" {
        // What Enable-SqlAlwaysOn sets, without needing the SqlServer module.
        let id = common::win_instance_id(inst)?
        if id == "" { return Err("SQL Server instance '" + inst + "' is not installed") }
        registry::write("HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\" + id + "\\MSSQLServer\\HADR", "HADR_Enabled", Value::Int(1), "dword")?
        common::win_restart_engine(inst)?
    } else {
        let set = shell::bash("/opt/mssql/bin/mssql-conf set hadr.hadrenabled 1", Value::Null)?
        if !set.success { return Err(common::cmd_error("mssql-conf set hadr.hadrenabled", set)) }
        let r = shell::bash("systemctl restart mssql-server", Value::Null)?
        if !r.success { return Err(common::cmd_error("systemctl restart mssql-server", r)) }
    }
    common::wait_for_engine(params, 180)
}

fn endpoint_url(params: Value) -> Result[string, string] {
    let host = common::run_scalar(params, "SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(128));")?
    Ok("TCP://" + host + ":" + str(common::param_int(params, "endpoint_port", 5022)))
}

fn checks(params: Value) -> Result[List[List[string]], string] {
    let ep = common::param_str(params, "endpoint_name", "Hadr_endpoint")
    let cert = common::param_str(params, "endpoint_certificate", "")
    let auth = if cert == "" { "m.connection_auth_desc <> N'CERTIFICATE'" } else {
        "c.name = " + common::tsql_lit(cert)
    }
    let endpoint = "EXISTS (SELECT 1 FROM sys.tcp_endpoints e JOIN sys.database_mirroring_endpoints m ON m.endpoint_id = e.endpoint_id " +
        "LEFT JOIN sys.certificates c ON c.certificate_id = m.certificate_id WHERE e.name = " + common::tsql_lit(ep)
    Ok([
        ["cluster_type", "ag.cluster_type_desc = " + common::tsql_lit(cluster_type(params)?.to_lower())],
        ["endpoint_port", endpoint + " AND e.port = " + str(common::param_int(params, "endpoint_port", 5022)) + ")"],
        ["endpoint_state", endpoint + " AND e.state_desc = N'STARTED')"],
        ["endpoint_certificate", endpoint + " AND " + auth + ")"],
        ["endpoint_url", "EXISTS (SELECT 1 FROM sys.availability_replicas r WHERE r.group_id = ag.group_id " +
            "AND r.replica_server_name = @@SERVERNAME AND r.endpoint_url = " + common::tsql_lit(endpoint_url(params)?) + ")"]
    ])
}

fn ag_from(name: string) -> string {
    "FROM sys.availability_groups ag WHERE ag.name = " + common::tsql_lit(name)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::require(params, "name")?
    if sys::family() != "windows" && common::param_str(params, "endpoint_certificate", "") == "" && common::want_present(params)? {
        return Err("'endpoint_certificate' is required on Linux: its mirroring endpoints cannot use Windows authentication")
    }
    if !hadr_enabled(params)? {
        if common::want_present(params)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let Some(d) = common::drift(params, ag_from(name), checks(params)?)? else {
        if common::want_present(params)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !common::want_present(params)? { return Ok(CheckResult::NotConfigured) }
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    // CLUSTER_TYPE is fixed when the group is created.
    if d.contains("cluster_type") {
        return Err("availability group '" + name + "' has a different cluster type; it can only change by dropping and recreating the group")
    }
    log::info("availability group '" + name + "' differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::require(params, "name")?
    if !common::want_present(params)? {
        // The endpoint and HADR stay: other groups may use them.
        if hadr_enabled(params)? {
            common::run_exec(params, "IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = " + common::tsql_lit(name) + ") " +
                "DROP AVAILABILITY GROUP " + common::tsql_id(name) + ";")?
        }
        return Ok(ApplyResult::Success)
    }

    // Enabling HADR restarts the engine; wait for it, then carry on.
    if !hadr_enabled(params)? {
        log::info("enabling Always On HADR (restarts the SQL Server service)")
        enable_hadr(params)?
        if !hadr_enabled(params)? { return Err("HADR is still disabled after enabling it and restarting SQL Server") }
    }

    let port = str(common::param_int(params, "endpoint_port", 5022))
    let ep = common::param_str(params, "endpoint_name", "Hadr_endpoint")
    let cert = common::param_str(params, "endpoint_certificate", "")
    let auth = if cert != "" { ", AUTHENTICATION = CERTIFICATE " + common::tsql_id(cert) } else { ", AUTHENTICATION = WINDOWS NEGOTIATE" }
    let srv = common::run_scalar(params, "SELECT @@SERVERNAME;")?
    let url = endpoint_url(params)?

    let endpoint = "IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = " + common::tsql_lit(ep) + ") " +
        "CREATE ENDPOINT " + common::tsql_id(ep) + " STATE = STARTED AS TCP (LISTENER_PORT = " + port +
        ") FOR DATABASE_MIRRORING (ROLE = ALL" + auth + "); " +
        "ELSE ALTER ENDPOINT " + common::tsql_id(ep) + " STATE = STARTED AS TCP (LISTENER_PORT = " + port +
        ") FOR DATABASE_MIRRORING (ROLE = ALL" + auth + "); "
    let ag = "IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = " + common::tsql_lit(name) + ") " +
        "CREATE AVAILABILITY GROUP " + common::tsql_id(name) + " WITH (CLUSTER_TYPE = " + cluster_type(params)? + ") " +
        "FOR REPLICA ON " + common::tsql_lit(srv) + " WITH (ENDPOINT_URL = " + common::tsql_lit(url) +
        ", AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL); " +
        "ELSE IF NOT EXISTS (SELECT 1 FROM sys.availability_replicas r JOIN sys.availability_groups g ON g.group_id = r.group_id " +
        "WHERE g.name = " + common::tsql_lit(name) + " AND r.replica_server_name = @@SERVERNAME AND r.endpoint_url = " + common::tsql_lit(url) + ") " +
        "ALTER AVAILABILITY GROUP " + common::tsql_id(name) + " MODIFY REPLICA ON " + common::tsql_lit(srv) +
        " WITH (ENDPOINT_URL = " + common::tsql_lit(url) + "); "
    common::run_exec(params, endpoint + ag)?
    Ok(ApplyResult::Success)
}
