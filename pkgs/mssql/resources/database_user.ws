use value
use log
use common

fn role_member_predicate(role: string, user: string) -> string {
    "EXISTS (SELECT 1 FROM sys.database_role_members rm " +
        "JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id AND r.name = " + common::tsql_lit(role) + " " +
        "JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id AND m.name = " + common::tsql_lit(user) + ")"
}

fn db_exists(params: Value, db: string) -> Result[bool, string] {
    Ok(common::run_scalar(params, "SELECT CASE WHEN DB_ID(" + common::tsql_lit(db) + ") IS NULL THEN '0' ELSE '1' END;")? == "1")
}

fn user_exists(params: Value, db: string, name: string) -> Result[bool, string] {
    let r = common::run_scalar(params, "USE " + common::tsql_id(db) + "; SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.database_principals WHERE name = " +
        common::tsql_lit(name) + ") THEN '1' ELSE '0' END;")?
    Ok(r == "1")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let db = common::require(params, "database")?
    let name = common::require(params, "name")?
    let present = common::want_present(params)?
    // The database may not exist yet during a check-only run (its creation is a
    // separate, earlier step); report not-configured rather than erroring.
    if !db_exists(params, db)? {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !present {
        if user_exists(params, db, name)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let login = common::require(params, "login")?
    // SUSER_SNAME(sid) is NULL for an orphaned user, which reads as drift.
    let checks = [
        ["login", "SUSER_SNAME(p.sid) = " + common::tsql_lit(login)],
        ["default_schema", "p.default_schema_name = " + common::tsql_lit(common::param_str(params, "default_schema", "dbo"))]
    ]
    for role in common::csv(common::param_str(params, "roles", "")) {
        checks.push(["role:" + role.replace(" ", "_"), role_member_predicate(role, name)])
    }
    let from = "FROM sys.database_principals p WHERE p.name = " + common::tsql_lit(name) + " AND p.type IN ('S','U','G')"
    let Some(d) = common::drift_in(params, db, from, checks)? else { return Ok(CheckResult::NotConfigured) }
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("user '" + name + "' in '" + db + "' differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let db = common::require(params, "database")?
    let name = common::require(params, "name")?
    let uid = common::tsql_id(name)
    let use_db = "USE " + common::tsql_id(db) + "; "
    if !common::want_present(params)? {
        if !db_exists(params, db)? { return Ok(ApplyResult::Success) }
        // DROP USER fails while the user owns a schema; that error surfaces as is.
        common::run_exec(params, use_db + "IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = " + common::tsql_lit(name) + ") " +
            "DROP USER " + uid + ";")?
        return Ok(ApplyResult::Success)
    }
    let login = common::require(params, "login")?
    let schema = common::tsql_id(common::param_str(params, "default_schema", "dbo"))

    // CREATE USER ... FOR LOGIN fails with an opaque T-SQL error when the login
    // is missing; surface the ordering problem explicitly instead.
    let login_exists = common::run_scalar(params, "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = " + common::tsql_lit(login) + ") THEN '1' ELSE '0' END;")?
    if login_exists == "0" { return Err("login '" + login + "' does not exist on the server; create it with mssql.login in an earlier step") }

    // An existing user is remapped (this also repairs an orphaned user) and
    // given the default schema in place.
    let upsert = "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = " + common::tsql_lit(name) + ") " +
        "CREATE USER " + uid + " FOR LOGIN " + common::tsql_id(login) + " WITH DEFAULT_SCHEMA = " + schema + "; " +
        "ELSE ALTER USER " + uid + " WITH LOGIN = " + common::tsql_id(login) + ", DEFAULT_SCHEMA = " + schema + "; "
    let roles = common::csv(common::param_str(params, "roles", ""))
    let role_adds = roles.fold("", |acc, role|
        acc + "IF NOT " + role_member_predicate(role, name) + " ALTER ROLE " + common::tsql_id(role) + " ADD MEMBER " + uid + "; ")
    common::run_exec(params, use_db + upsert + role_adds)?
    Ok(ApplyResult::Success)
}
