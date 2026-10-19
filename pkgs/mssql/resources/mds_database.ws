use value
use sys
use log
use common
use mds

// A Master Data Services database, created as MDS Configuration Manager
// creates it (lib/mds.ws). SQL Server 2019 and older only.

struct Want {
    name: string,
    server: string,
    collation: string,
    admin: string,
    dir: string,
}

fn want(params: Value) -> Result[Want, string] {
    if sys::family() != "windows" { return Err("mssql.mds_database is Windows only") }
    let name = common::require(params, "name")?
    if !common::only_chars(name, "_-$") { return Err("invalid 'name' '" + name + "' (letters, digits, _, - and $)") }
    let server = common::param_str(params, "server", "localhost")
    if server == "" || server.contains("'") || server.contains(";") { return Err("invalid 'server' '" + server + "'") }
    let collation = common::param_str(params, "collation", "")
    common::check_collation(collation)?
    let admin = common::param_str(params, "administrator", "")
    common::no_newlines("administrator", admin)?
    let dir = mds::locate("mds_database", common::param_str(params, "mds_version", ""))?
    Ok(Want { name: name, server: server, collation: collation, admin: admin, dir: dir })
}

fn conn(w: Want) -> Value { Value::Map(#{ "server": Value::String(w.server) }) }

// "none" (no database), "other" (a database that is not an MDS one), or
// "mds|<collation>|<administrator>".
fn probe(w: Want) -> Result[string, string] {
    let kind = common::run_scalar(conn(w), "IF DB_ID(" + common::tsql_lit(w.name) + ") IS NULL SELECT N'none' " +
        "ELSE IF OBJECT_ID(" + common::tsql_lit(common::tsql_id(w.name) + ".mdm.tblModel") + ") IS NULL SELECT N'other' ELSE SELECT N'mds';")?
    if kind != "mds" { return Ok(kind) }
    let facts = common::run_scalar(conn(w), "SELECT CAST(DATABASEPROPERTYEX(" + common::tsql_lit(w.name) + ", 'Collation') AS nvarchar(128)) + N'|' + " +
        "ISNULL((SELECT UserName FROM " + common::tsql_id(w.name) + ".mdm.tblUser WHERE ID = 1), N'');")?
    Ok("mds|" + facts)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let w = want(params)?
    let p = probe(w)?
    if !common::want_present(params)? {
        if p == "none" { return Ok(CheckResult::AlreadyConfigured) }
        if p == "other" { return Err("database " + w.name + " on " + w.server + " is not a Master Data Services database, so mssql.mds_database will not drop it") }
        return Ok(CheckResult::NotConfigured)
    }
    if w.admin == "" { return Err("'administrator' is required (the Windows account that becomes the MDS system administrator)") }
    if p == "none" { return Ok(CheckResult::NotConfigured) }
    if p == "other" { return Err("database " + w.name + " exists on " + w.server + " but is not a Master Data Services database (no mdm.tblModel)") }
    let f = p.split("|")
    let have_coll = f.get(1).unwrap_or("")
    let have_admin = f.get(2).unwrap_or("")
    // Neither can change in place: MDS has no supported way to move the
    // system administrator, and a collation change means recreating the
    // database.
    if w.collation != "" && w.collation.to_lower() != have_coll.to_lower() {
        return Err("MDS database " + w.name + " has collation " + have_coll + ", not " + w.collation + "; the collation of an MDS database cannot change in place")
    }
    if have_admin.to_lower() != w.admin.to_lower() {
        return Err("the system administrator of MDS database " + w.name + " is " + have_admin + ", not " + w.admin +
            "; MDS 2019 and older have no supported way to change it on an existing database")
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    let p = probe(w)?
    if !common::want_present(params)? {
        if p == "none" { return Ok(ApplyResult::Success) }
        if p == "other" { return Err("database " + w.name + " on " + w.server + " is not a Master Data Services database, so mssql.mds_database will not drop it") }
        log::info("dropping MDS database " + w.name)
        let db = common::tsql_id(w.name)
        common::run_exec(conn(w), "ALTER DATABASE " + db + " SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE " + db + ";")?
        return Ok(ApplyResult::Success)
    }
    if p != "none" { return Ok(ApplyResult::Success) }
    // An empty collation means the server's, as Configuration Manager offers.
    let coll = if w.collation != "" { w.collation } else {
        common::run_scalar(conn(w), "SELECT CAST(SERVERPROPERTY('Collation') AS nvarchar(128));")?
    }
    log::info("creating MDS database " + w.name + " on " + w.server)
    let body = mds::connect_ps(w.server) +
        "$di = [Activator]::CreateInstance($tDb, $true)\n" +
        "Set-CwProp $di 'Name' " + common::ps_q(w.name) + "\n" +
        "Set-CwProp $di 'Collation' " + common::ps_q(coll) + "\n" +
        "Set-CwProp $di 'MdsAdministrator' " + common::ps_q(w.admin) + "\n" +
        "Set-CwProp $di 'Server' $srvInfo\n" +
        "[void](Invoke-CwMds $admin $tAdmin 'CreateDatabase' @($di))\n"
    mds::run(w.dir, "creating MDS database " + w.name, body, #{})?
    Ok(ApplyResult::Success)
}
