use value
use log
use common

// Reads [configured value, value in use, is_advanced] for the setting.
fn current(params: Value, name: string) -> Result[List[string], string] {
    let r = common::run_scalar(params,
        "SELECT CONCAT(CAST(value AS bigint), N' ', CAST(value_in_use AS bigint), N' ', CAST(is_advanced AS int)) " +
        "FROM sys.configurations WHERE name = " + common::tsql_lit(name) + ";")?
    if r == "" { return Err("unknown sp_configure setting: " + name) }
    Ok(r.split(" "))
}

// Compares the configured `value`, not `value_in_use`: a restart-only option
// keeps its old running value until SQL Server restarts, and comparing that
// would re-apply (and fail the re-check) on every run.
fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::require(params, "name")?
    let want = str(common::param_int(params, "value", 0))
    let cur = current(params, name)?
    if cur[0] != want { return Ok(CheckResult::NotConfigured) }
    if cur[1] != want {
        log::warn("'" + name + "' is set to " + want + " but " + cur[1] + " is in use until SQL Server restarts")
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::require(params, "name")?
    let value = str(common::param_int(params, "value", 0))
    let cur = current(params, name)?
    let set = "EXEC sp_configure " + common::tsql_lit(name) + ", " + value + "; RECONFIGURE WITH OVERRIDE; "
    // An advanced option can only be set while 'show advanced options' is on;
    // turn it on for this batch and put it back afterwards.
    let batch = if cur[2] == "1" && name != "show advanced options" {
        "DECLARE @adv int = (SELECT CAST(value AS int) FROM sys.configurations WHERE name = N'show advanced options'); " +
            "IF @adv = 0 BEGIN EXEC sp_configure N'show advanced options', 1; RECONFIGURE; END; " +
            set +
            "IF @adv = 0 BEGIN EXEC sp_configure N'show advanced options', 0; RECONFIGURE; END;"
    } else { set }
    common::run_exec(params, batch)?
    let after = current(params, name)?
    if after[1] != value {
        log::warn("'" + name + "' takes effect after SQL Server restarts (in use: " + after[1] + ")")
    }
    Ok(ApplyResult::Success)
}
