use value
use log
use common

// The recovery_model symbol as SQL Server spells it; "" leaves it alone.
fn recovery_model(params: Value) -> Result[string, string] {
    let rm = common::param_str(params, "recovery_model", "unmanaged")
    if rm == "unmanaged" { return Ok("") }
    if rm == "full" { return Ok("FULL") }
    if rm == "simple" { return Ok("SIMPLE") }
    if rm == "bulk_logged" { return Ok("BULK_LOGGED") }
    Err("invalid 'recovery_model' value '" + rm + "' (expected :unmanaged, :full, :simple or :bulk_logged)")
}

fn checks(params: Value) -> Result[List[List[string]], string] {
    let out = []
    let rm = recovery_model(params)?
    if rm != "" { out.push(["recovery_model", "d.recovery_model_desc = " + common::tsql_lit(rm)]) }
    let coll = common::param_str(params, "collation", "")
    common::check_collation(coll)?
    if coll != "" { out.push(["collation", "d.collation_name = " + common::tsql_lit(coll)]) }
    let owner = common::param_str(params, "owner", "")
    if owner != "" { out.push(["owner", "SUSER_SNAME(d.owner_sid) = " + common::tsql_lit(owner)]) }
    let complvl = common::param_int(params, "compatibility_level", 0)
    if complvl != 0 { out.push(["compatibility_level", "d.compatibility_level = " + str(complvl)]) }
    Ok(out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::require(params, "name")?
    if !common::want_present(params)? {
        let r = common::run_scalar(params, "SELECT CASE WHEN DB_ID(" + common::tsql_lit(name) + ") IS NULL THEN 'GONE' ELSE 'PRESENT' END;")?
        if r == "GONE" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let from = "FROM sys.databases d WHERE d.name = " + common::tsql_lit(name)
    let Some(d) = common::drift(params, from, checks(params)?)? else { return Ok(CheckResult::NotConfigured) }
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("database '" + name + "' differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::require(params, "name")?
    let id = common::tsql_id(name)
    let lit = common::tsql_lit(name)
    if !common::want_present(params)? {
        common::run_exec(params, "IF DB_ID(" + lit + ") IS NOT NULL BEGIN " +
            "ALTER DATABASE " + id + " SET SINGLE_USER WITH ROLLBACK IMMEDIATE; " +
            "DROP DATABASE " + id + "; END;")?
        return Ok(ApplyResult::Success)
    }
    checks(params)?
    let coll = common::param_str(params, "collation", "")
    let coll_clause = if coll != "" { " COLLATE " + coll } else { "" }
    let create = "IF DB_ID(" + lit + ") IS NULL CREATE DATABASE " + id + coll_clause + "; "
    // ALTER DATABASE COLLATE needs the database to itself, and fails when
    // schema-bound objects depend on the current collation.
    let coll_stmt = if coll != "" {
        "IF (SELECT collation_name FROM sys.databases WHERE name = " + lit + ") <> " + common::tsql_lit(coll) +
            " ALTER DATABASE " + id + " COLLATE " + coll + "; "
    } else { "" }
    let rm = recovery_model(params)?
    let rm_stmt = if rm != "" { "ALTER DATABASE " + id + " SET RECOVERY " + rm + " WITH NO_WAIT; " } else { "" }
    let complvl = common::param_int(params, "compatibility_level", 0)
    let cl_stmt = if complvl != 0 { "ALTER DATABASE " + id + " SET COMPATIBILITY_LEVEL = " + str(complvl) + "; " } else { "" }
    let owner = common::param_str(params, "owner", "")
    let owner_stmt = if owner != "" {
        "IF SUSER_SNAME((SELECT owner_sid FROM sys.databases WHERE name = " + lit + ")) IS NULL OR SUSER_SNAME((SELECT owner_sid FROM sys.databases WHERE name = " + lit + ")) <> " + common::tsql_lit(owner) +
            " ALTER AUTHORIZATION ON DATABASE::" + id + " TO " + common::tsql_id(owner) + "; "
    } else { "" }
    common::run_exec(params, create + coll_stmt + rm_stmt + cl_stmt + owner_stmt)?
    Ok(ApplyResult::Success)
}
