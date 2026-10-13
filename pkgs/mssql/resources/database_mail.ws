use value
use log
use common

// The account description doubles as the record of which password revision
// was last applied: Database Mail keeps the SMTP password in a credential
// that cannot be read back, so a changed password is otherwise invisible.
fn revision_marker(params: Value) -> string {
    let rev = common::param_str(params, "password_revision", "")
    if rev == "" { "" } else { "config-weave password revision: " + rev }
}

fn link_predicate(profile: string, account: string) -> string {
    "EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount pa " +
        "JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id AND p.name = " + common::tsql_lit(profile) + " " +
        "JOIN msdb.dbo.sysmail_account a ON a.account_id = pa.account_id AND a.name = " + common::tsql_lit(account) + ")"
}

fn account_checks(params: Value) -> List[List[string]] {
    let user = common::param_str(params, "smtp_user", "")
    let user_cond = if user == "" { "s.username IS NULL" } else { "s.username = " + common::tsql_lit(user) }
    let out = [
        ["from_address", "a.email_address = " + common::tsql_lit(common::param_str(params, "from_address", ""))],
        ["smtp_server", "s.servername = " + common::tsql_lit(common::param_str(params, "smtp_server", ""))],
        ["port", "s.port = " + str(common::param_int(params, "port", 25))],
        ["use_ssl", "s.enable_ssl = " + common::tsql_bool(common::param_bool(params, "use_ssl", false))],
        ["smtp_user", user_cond]
    ]
    let marker = revision_marker(params)
    if marker != "" { out.push(["password_revision", "a.description = " + common::tsql_lit(marker)]) }
    out
}

fn account_from(account: string) -> string {
    "FROM msdb.dbo.sysmail_account a JOIN msdb.dbo.sysmail_server s ON s.account_id = a.account_id " +
        "WHERE a.name = " + common::tsql_lit(account)
}

fn names(params: Value) -> Result[List[string], string] {
    let profile = common::require(params, "profile")?
    let account = common::require(params, "account")?
    Ok([profile, account])
}

fn check(params: Value) -> Result[CheckResult, string] {
    let n = names(params)?
    let profile = n[0]
    let account = n[1]
    let objs = common::run_scalar(params, "SELECT CONCAT(" +
        "CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = " + common::tsql_lit(profile) + ") THEN 'P' ELSE '-' END, " +
        "CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = " + common::tsql_lit(account) + ") THEN 'A' ELSE '-' END, " +
        "CASE WHEN " + link_predicate(profile, account) + " THEN 'L' ELSE '-' END, " +
        "CASE WHEN (SELECT CAST(value AS int) FROM sys.configurations WHERE name = N'Database Mail XPs') = 1 THEN 'X' ELSE '-' END);")?
    if !common::want_present(params)? {
        // An account another profile still uses is deliberately kept.
        let left = common::run_scalar(params, "SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = " + common::tsql_lit(profile) + ") " +
            "OR EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account a WHERE a.name = " + common::tsql_lit(account) +
            " AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount pa WHERE pa.account_id = a.account_id)) THEN '1' ELSE '0' END;")?
        if left == "0" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if objs != "PALX" {
        log::info("database mail objects present: " + objs + " (want PALX: profile, account, link, Database Mail XPs)")
        return Ok(CheckResult::NotConfigured)
    }
    let Some(d) = common::drift(params, account_from(account), account_checks(params))? else { return Ok(CheckResult::NotConfigured) }
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("mail account '" + account + "' differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let n = names(params)?
    let profile = common::tsql_lit(n[0])
    let account = common::tsql_lit(n[1])
    if !common::want_present(params)? {
        // The account goes too unless another profile still uses it.
        // Database Mail XPs is left on: other profiles may rely on it.
        common::run_exec(params,
            "IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = " + profile + ") " +
            "EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name = " + profile + "; " +
            "IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = " + account + ") " +
            "AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount pa JOIN msdb.dbo.sysmail_account a " +
            "ON a.account_id = pa.account_id WHERE a.name = " + account + ") " +
            "EXEC msdb.dbo.sysmail_delete_account_sp @account_name = " + account + ";")?
        return Ok(ApplyResult::Success)
    }

    // sysmail_update_account_sp resets every argument it is not given (an
    // omitted username drops the SMTP credential), so both calls get them all.
    let user = common::param_str(params, "smtp_user", "")
    let auth_args = if user != "" {
        ", @username = " + common::tsql_lit(user) + ", @password = " + common::tsql_lit(common::param_str(params, "smtp_password", ""))
    } else { "" }
    let account_args = "@email_address = " + common::tsql_lit(common::param_str(params, "from_address", "")) +
        ", @mailserver_name = " + common::tsql_lit(common::param_str(params, "smtp_server", "")) +
        ", @port = " + str(common::param_int(params, "port", 25)) +
        ", @enable_ssl = " + common::tsql_bool(common::param_bool(params, "use_ssl", false)) +
        ", @description = " + common::tsql_lit(revision_marker(params)) +
        auth_args
    let in_sync = common::drift(params, account_from(n[1]), account_checks(params))?
    let upsert = if let Some(d) = in_sync {
        if d.is_empty() { "" } else {
            "EXEC msdb.dbo.sysmail_update_account_sp @account_name = " + account + ", " + account_args + "; "
        }
    } else {
        "EXEC msdb.dbo.sysmail_add_account_sp @account_name = " + account + ", " + account_args + "; "
    }
    let enable = "IF (SELECT CAST(value AS int) FROM sys.configurations WHERE name = N'Database Mail XPs') = 0 BEGIN " +
        "DECLARE @adv int = (SELECT CAST(value AS int) FROM sys.configurations WHERE name = N'show advanced options'); " +
        "IF @adv = 0 BEGIN EXEC sp_configure N'show advanced options', 1; RECONFIGURE; END; " +
        "EXEC sp_configure N'Database Mail XPs', 1; RECONFIGURE; " +
        "IF @adv = 0 BEGIN EXEC sp_configure N'show advanced options', 0; RECONFIGURE; END; END; "
    let add_profile = "IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = " + profile + ") " +
        "EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = " + profile + "; "
    let add_link = "IF NOT " + link_predicate(n[0], n[1]) + " " +
        "EXEC msdb.dbo.sysmail_add_profileaccount_sp @profile_name = " + profile +
        ", @account_name = " + account + ", @sequence_number = 1; "
    common::run_exec(params, enable + upsert + add_profile + add_link)?
    Ok(ApplyResult::Success)
}
