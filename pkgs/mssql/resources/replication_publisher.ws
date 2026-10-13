use value
use common

// [sys.databases flag column, sp_replicationdboption option name] for `type`.
fn kind(params: Value) -> Result[List[string], string] {
    let t = common::param_str(params, "type", "publish")
    if t == "publish" { return Ok(["is_published", "publish"]) }
    if t == "merge" { return Ok(["is_merge_published", "merge publish"]) }
    Err("invalid 'type' value '" + t + "' (expected :publish or :merge)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let db = common::require(params, "publisher_db")?
    let k = kind(params)?
    let r = common::run_scalar(params, "SELECT CAST(" + k[0] + " AS varchar(1)) FROM sys.databases WHERE name = " + common::tsql_lit(db) + ";")?
    let present = common::want_present(params)?
    // The database may not exist yet during a check-only run.
    if r == "" {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if (r == "1") == present { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let db = common::require(params, "publisher_db")?
    let k = kind(params)?
    let present = common::want_present(params)?
    let want = common::tsql_bool(present)
    let value = if present { "N'true'" } else { "N'false'" }
    if present && common::run_scalar(params, "SELECT CASE WHEN DB_ID(" + common::tsql_lit(db) + ") IS NULL THEN '0' ELSE '1' END;")? == "0" {
        return Err("database '" + db + "' does not exist; create it with mssql.database in an earlier step")
    }
    // Turning the option off fails while the database still has publications.
    common::run_exec(params, "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = " + common::tsql_lit(db) + " AND " + k[0] + " <> " + want + ") " +
        "EXEC sp_replicationdboption @dbname = " + common::tsql_lit(db) +
        ", @optname = " + common::tsql_lit(k[1]) + ", @value = " + value + ";")?
    Ok(ApplyResult::Success)
}
