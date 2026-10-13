use value
use log
use common

fn agent_running(params: Value) -> bool {
    let q = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status_desc = 'Running') THEN '1' ELSE '0' END;"
    if let Ok(r) = common::run_scalar(params, q) { return r == "1" }
    false
}

// "1" or "0" for is_cdc_enabled, "" when the database does not exist.
fn cdc_state(params: Value, db: string) -> Result[string, string] {
    common::run_scalar(params, "SELECT CAST(is_cdc_enabled AS varchar(1)) FROM sys.databases WHERE name = " + common::tsql_lit(db) + ";")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let db = common::require(params, "database")?
    let present = common::want_present(params)?
    let r = cdc_state(params, db)?
    // The database may not exist yet during a check-only run (its creation is a
    // separate, earlier step); report not-configured rather than erroring.
    if r == "" {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if (r == "1") == present { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let db = common::require(params, "database")?
    let present = common::want_present(params)?
    if cdc_state(params, db)? == "" {
        if present { return Err("database '" + db + "' does not exist; create it with mssql.database in an earlier step") }
        return Ok(ApplyResult::Success)
    }
    if present && !agent_running(params) {
        log::warn("SQL Server Agent is not running; CDC capture jobs will not run until it is started")
    }
    let batch = if present {
        "USE " + common::tsql_id(db) + "; " +
            "IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 0 EXEC sys.sp_cdc_enable_db;"
    } else {
        "USE " + common::tsql_id(db) + "; " +
            "IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 1 EXEC sys.sp_cdc_disable_db;"
    }
    common::run_exec(params, batch)?
    Ok(ApplyResult::Success)
}
