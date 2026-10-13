use value
use log
use common

// This server registered as a publisher on its own distributor, by name.
// MSdistpublishers stores the name upper-cased, hence the UPPER().
fn publisher_from() -> string {
    "FROM msdb.dbo.MSdistpublishers p WHERE UPPER(p.name) = UPPER(@@SERVERNAME)"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let db = common::param_str(params, "distribution_db", "distribution")
    let state = common::run_scalar(params,
        "SELECT CONCAT(" +
        "CASE WHEN EXISTS (SELECT 1 FROM sys.servers WHERE is_distributor = 1) THEN 'D' ELSE '-' END, " +
        "CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name = " + common::tsql_lit(db) + " AND is_distributor = 1) THEN 'B' ELSE '-' END, " +
        "CASE WHEN OBJECT_ID(N'msdb.dbo.MSdistpublishers') IS NOT NULL THEN 'P' ELSE '-' END);")?
    if !common::want_present(params)? {
        if state == "---" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if state != "DBP" { return Ok(CheckResult::NotConfigured) }
    let pub_db = common::run_scalar(params, "SELECT p.distribution_db " + publisher_from() + ";")?
    // A failed sp_adddistpublisher leaves the distributor and its database in
    // place, so the publisher row is what proves setup finished.
    if pub_db == "" { return Ok(CheckResult::NotConfigured) }
    if pub_db.to_lower() != db.to_lower() {
        return Err("this server publishes through distribution database '" + pub_db + "', not '" + db +
            "'; moving it means dropping its publications, so it is left to you")
    }
    let wd = common::param_str(params, "working_directory", "")
    if wd != "" {
        let Some(d) = common::drift(params, publisher_from(), [["working_directory", "p.working_directory = " + common::tsql_lit(wd)]])? else {
            return Ok(CheckResult::NotConfigured)
        }
        if !d.is_empty() {
            log::info("distribution publisher working directory differs")
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

// Sets @has to 1 when this server is registered as a publisher. Dynamic SQL,
// because MSdistpublishers only exists once sp_adddistributor has run.
fn has_publisher_sql() -> string {
    "SET @has = 0; IF OBJECT_ID(N'msdb.dbo.MSdistpublishers') IS NOT NULL " +
        "EXEC sp_executesql N'SELECT @h = 1 FROM msdb.dbo.MSdistpublishers WHERE UPPER(name) = UPPER(@@SERVERNAME)', " +
        "N'@h bit OUTPUT', @h = @has OUTPUT; "
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let db = common::tsql_lit(common::param_str(params, "distribution_db", "distribution"))
    let head = "DECLARE @srv sysname = @@SERVERNAME; DECLARE @has bit; " + has_publisher_sql()
    if !common::want_present(params)? {
        // Fails while publications still exist; drop them first.
        common::run_exec(params, head +
            "IF @has = 1 EXEC sp_dropdistpublisher @publisher = @srv; " +
            "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = " + db + " AND is_distributor = 1) " +
            "EXEC sp_dropdistributiondb @database = " + db + "; " +
            "IF EXISTS (SELECT 1 FROM sys.servers WHERE is_distributor = 1) EXEC sp_dropdistributor;")?
        return Ok(ApplyResult::Success)
    }
    let wd = common::param_str(params, "working_directory", "")
    let wd_arg = if wd != "" { ", @working_directory = " + common::tsql_lit(wd) } else { "" }
    let wd_update = if wd != "" {
        "ELSE EXEC sp_changedistpublisher @publisher = @srv, @property = N'working_directory', @value = " + common::tsql_lit(wd) + "; "
    } else { "" }
    let batch = head +
        "IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE is_distributor = 1) " +
        "EXEC sp_adddistributor @distributor = @srv; " +
        "IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = " + db + " AND is_distributor = 1) " +
        "EXEC sp_adddistributiondb @database = " + db + ", @security_mode = 1; " +
        has_publisher_sql() +
        "IF @has = 0 EXEC sp_adddistpublisher @publisher = @srv, @distribution_db = " + db + ", @security_mode = 1" + wd_arg + "; " +
        wd_update
    common::run_exec(params, batch)?
    Ok(ApplyResult::Success)
}
