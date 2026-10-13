use value
use log
use common

fn exists_query(name: string) -> string {
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = " + common::tsql_lit(name) +
        ") THEN 'PRESENT' ELSE 'GONE' END;"
}

fn want_sql(params: Value) -> Result[bool, string] {
    let a = common::param_str(params, "auth", "windows")
    if a == "sql" { return Ok(true) }
    if a == "windows" { return Ok(false) }
    Err("invalid 'auth' value '" + a + "' (expected :windows or :sql)")
}

fn role_member_predicate(role: string, login: string) -> string {
    "EXISTS (SELECT 1 FROM sys.server_role_members rm " +
        "JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id AND r.name = " + common::tsql_lit(role) + " " +
        "JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id AND m.name = " + common::tsql_lit(login) + ")"
}

// The current login type: "sql", "windows" or "" when the login is missing.
fn current_auth(params: Value, name: string) -> Result[string, string] {
    common::run_scalar(params,
        "SELECT CASE type WHEN 'S' THEN 'sql' ELSE 'windows' END FROM sys.server_principals " +
        "WHERE name = " + common::tsql_lit(name) + " AND type IN ('S','U','G');")
}

// Every property the resource manages, compared server-side. The SQL login
// password is compared with PWDCOMPARE, which needs the connecting login to
// hold CONTROL SERVER (sysadmin); without it password_hash reads NULL and
// the password counts as drifted.
fn checks(params: Value, name: string, sql: bool) -> List[List[string]] {
    let out = [
        ["enabled", "p.is_disabled = " + common::tsql_bool(!common::param_bool(params, "enabled", true))],
        ["default_database", "p.default_database_name = " + common::tsql_lit(common::param_str(params, "default_database", "master"))]
    ]
    let lang = common::param_str(params, "default_language", "")
    if lang != "" { out.push(["default_language", "p.default_language_name = " + common::tsql_lit(lang)]) }
    if sql {
        out.push(["check_policy", "l.is_policy_checked = " + common::tsql_bool(common::param_bool(params, "check_policy", false))])
        out.push(["check_expiration", "l.is_expiration_checked = " + common::tsql_bool(common::param_bool(params, "check_expiration", false))])
        out.push(["password", "PWDCOMPARE(" + common::tsql_lit(common::param_str(params, "password", "")) + ", l.password_hash) = 1"])
    }
    for role in common::csv(common::param_str(params, "server_roles", "")) {
        out.push(["server_role:" + role.replace(" ", "_"), role_member_predicate(role, name)])
    }
    out
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::require(params, "name")?
    if !common::want_present(params)? {
        if common::run_scalar(params, exists_query(name))? == "GONE" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let sql = want_sql(params)?
    if sql && common::param_str(params, "password", "") == "" { return Err("SQL logins require a 'password'") }
    let have = current_auth(params, name)?
    if have == "" { return Ok(CheckResult::NotConfigured) }
    let want = if sql { "sql" } else { "windows" }
    if have != want {
        if common::param_bool(params, "recreate_on_auth_change", false) { return Ok(CheckResult::NotConfigured) }
        return Err("login '" + name + "' exists with " + have + " authentication but 'auth' is :" + want +
            "; changing it drops and recreates the login, which gives it a new SID and orphans its database users. " +
            "Set recreate_on_auth_change = true to allow that")
    }
    let from = "FROM sys.server_principals p LEFT JOIN sys.sql_logins l ON l.principal_id = p.principal_id " +
        "WHERE p.name = " + common::tsql_lit(name)
    let Some(d) = common::drift(params, from, checks(params, name, sql))? else { return Ok(CheckResult::NotConfigured) }
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("login '" + name + "' differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::require(params, "name")?
    let id = common::tsql_id(name)
    if !common::want_present(params)? {
        common::run_exec(params, "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = " + common::tsql_lit(name) + ") " +
            "DROP LOGIN " + id + ";")?
        return Ok(ApplyResult::Success)
    }
    let sql = want_sql(params)?
    let pw = common::param_str(params, "password", "")
    if sql && pw == "" { return Err("SQL logins require a 'password'") }
    let db = common::tsql_id(common::param_str(params, "default_database", "master"))
    let lang = common::param_str(params, "default_language", "")
    let lang_opt = if lang != "" { ", DEFAULT_LANGUAGE = " + common::tsql_id(lang) } else { "" }
    let policy = if common::param_bool(params, "check_policy", false) { "ON" } else { "OFF" }
    let expiry = if common::param_bool(params, "check_expiration", false) { "ON" } else { "OFF" }

    let have = current_auth(params, name)?
    let want = if sql { "sql" } else { "windows" }
    let drop = if have != "" && have != want {
        // check() only lets this through with recreate_on_auth_change.
        log::warn("recreating login '" + name + "' to change its authentication type; database users mapped to it are orphaned")
        "DROP LOGIN " + id + "; "
    } else { "" }

    // CHECK_EXPIRATION = ON is rejected while CHECK_POLICY is OFF, so the
    // policy is set before expiration when turning on and after it when off.
    let create = if have == "" || drop != "" {
        if sql {
            "CREATE LOGIN " + id + " WITH PASSWORD = " + common::tsql_lit(pw) + ", DEFAULT_DATABASE = " + db + lang_opt +
                ", CHECK_POLICY = " + policy + ", CHECK_EXPIRATION = " + expiry + "; "
        } else {
            "CREATE LOGIN " + id + " FROM WINDOWS WITH DEFAULT_DATABASE = " + db + lang_opt + "; "
        }
    } else { "" }
    let alter = "ALTER LOGIN " + id + " WITH DEFAULT_DATABASE = " + db + lang_opt + "; "
    let sql_alter = if sql {
        let pw_stmt = "IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = " + common::tsql_lit(name) +
            " AND PWDCOMPARE(" + common::tsql_lit(pw) + ", password_hash) = 1) ALTER LOGIN " + id + " WITH PASSWORD = " + common::tsql_lit(pw) + "; "
        let pol = if policy == "ON" {
            "ALTER LOGIN " + id + " WITH CHECK_POLICY = ON; ALTER LOGIN " + id + " WITH CHECK_EXPIRATION = " + expiry + "; "
        } else {
            "ALTER LOGIN " + id + " WITH CHECK_EXPIRATION = " + expiry + "; ALTER LOGIN " + id + " WITH CHECK_POLICY = OFF; "
        }
        pol + pw_stmt
    } else { "" }
    let state = if common::param_bool(params, "enabled", true) { "ALTER LOGIN " + id + " ENABLE; " } else { "ALTER LOGIN " + id + " DISABLE; " }
    let roles = common::csv(common::param_str(params, "server_roles", ""))
    let role_adds = roles.fold("", |acc, role|
        acc + "IF NOT " + role_member_predicate(role, name) + " ALTER SERVER ROLE " + common::tsql_id(role) + " ADD MEMBER " + id + "; ")

    common::run_exec(params, drop + create + alter + sql_alter + state + role_adds)?
    Ok(ApplyResult::Success)
}
