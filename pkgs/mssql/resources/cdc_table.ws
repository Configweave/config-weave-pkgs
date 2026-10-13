use value
use log
use common

fn capture_name(params: Value) -> string {
    let ci = common::param_str(params, "capture_instance", "")
    if ci != "" { return ci }
    common::param_str(params, "schema", "dbo") + "_" + common::param_str(params, "table", "")
}

// "1" when the database exists with CDC enabled, so cdc.change_tables exists.
fn cdc_ready(params: Value, db: string) -> Result[bool, string] {
    let r = common::run_scalar(params, "SELECT CASE WHEN DB_ID(" + common::tsql_lit(db) + ") IS NOT NULL AND " +
        "(SELECT ISNULL(is_cdc_enabled, 0) FROM sys.databases WHERE name = " + common::tsql_lit(db) + ") = 1 THEN '1' ELSE '0' END;")?
    Ok(r == "1")
}

fn from_clause(params: Value, ci: string) -> string {
    "FROM cdc.change_tables ct " +
        "JOIN sys.tables t ON t.object_id = ct.source_object_id " +
        "JOIN sys.schemas s ON s.schema_id = t.schema_id " +
        "WHERE s.name = " + common::tsql_lit(common::param_str(params, "schema", "dbo")) +
        " AND t.name = " + common::tsql_lit(common::param_str(params, "table", "")) +
        " AND ct.capture_instance = " + common::tsql_lit(ci)
}

fn checks(params: Value) -> List[List[string]] {
    let role = common::param_str(params, "role_name", "")
    let role_cond = if role == "" { "ct.role_name IS NULL" } else { "ct.role_name = " + common::tsql_lit(role) }
    [
        ["role_name", role_cond],
        ["supports_net_changes", "ct.supports_net_changes = " + common::tsql_bool(common::param_bool(params, "supports_net_changes", true))]
    ]
}

// None when the capture instance is missing, else the drifted properties.
fn current(params: Value, db: string) -> Result[Option[List[string]], string] {
    if !cdc_ready(params, db)? { return Ok(None) }
    common::drift_in(params, db, from_clause(params, capture_name(params)), checks(params))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let db = common::require(params, "database")?
    let table = common::require(params, "table")?
    let ci = capture_name(params)
    let cur = current(params, db)?
    if !common::want_present(params)? {
        if cur.is_none() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let Some(d) = cur else { return Ok(CheckResult::NotConfigured) }
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    // A capture instance's options are fixed when it is created; changing
    // them means disabling it, which discards the change data it holds.
    if !common::param_bool(params, "recreate_on_change", false) {
        return Err("capture instance '" + ci + "' on " + table + " differs in " + d.join(", ") +
            ", which can only change by recreating it (losing its captured changes); set recreate_on_change = true to allow that")
    }
    log::info("capture instance '" + ci + "' differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let db = common::require(params, "database")?
    let table = common::require(params, "table")?
    let schema = common::param_str(params, "schema", "dbo")
    let ci = capture_name(params)
    let use_db = "USE " + common::tsql_id(db) + "; "
    let cur = current(params, db)?
    let disable = "EXEC sys.sp_cdc_disable_table @source_schema = " + common::tsql_lit(schema) +
        ", @source_name = " + common::tsql_lit(table) + ", @capture_instance = " + common::tsql_lit(ci) + "; "
    if !common::want_present(params)? {
        if cur.is_some() { common::run_exec(params, use_db + disable)? }
        return Ok(ApplyResult::Success)
    }
    if !cdc_ready(params, db)? {
        return Err("CDC is not enabled on database '" + db + "'; apply mssql.database_cdc first")
    }
    let role = common::param_str(params, "role_name", "")
    let role_arg = if role != "" { common::tsql_lit(role) } else { "NULL" }
    let enable = "EXEC sys.sp_cdc_enable_table @source_schema = " + common::tsql_lit(schema) +
        ", @source_name = " + common::tsql_lit(table) +
        ", @role_name = " + role_arg +
        ", @capture_instance = " + common::tsql_lit(ci) +
        ", @supports_net_changes = " + common::tsql_bool(common::param_bool(params, "supports_net_changes", true)) + ";"
    let batch = if let Some(d) = cur {
        if d.is_empty() { return Ok(ApplyResult::Success) }
        log::warn("recreating capture instance " + ci + "; its captured changes are discarded")
        disable + enable
    } else {
        log::info("enabling CDC capture instance " + ci + " on " + schema + "." + table)
        enable
    }
    common::run_exec(params, use_db + batch)?
    Ok(ApplyResult::Success)
}
