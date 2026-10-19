use value
use fs
use path
use shell
use sys
use registry
use log
use common
use ssas
use xmlfile

fn instance_name(params: Value) -> Result[string, string] {
    let inst = common::param_str(params, "instance", "MSSQLSERVER")
    if inst == "" { return Err("'instance' must not be empty (MSSQLSERVER is the default instance)") }
    common::check_instance(inst)?
    Ok(inst)
}

fn want_sql_auth(params: Value) -> Result[bool, string] {
    let m = common::param_str(params, "security_mode", "windows")
    if m == "sql" { return Ok(true) }
    if m == "windows" { return Ok(false) }
    Err("invalid 'security_mode' value '" + m + "' (expected :windows or :sql)")
}

fn edition(params: Value) -> Result[string, string] {
    let e = common::param_str(params, "edition", "Developer")
    if !common::only_chars(e, "-") { return Err("invalid 'edition' '" + e + "' (an edition name or a 25-character product key)") }
    Ok(e)
}

// True when the edition is a product key rather than a name.
fn is_product_key(e: string) -> bool { e.contains("-") }

// Whether SERVERPROPERTY('Edition') matches the edition param. A product key
// cannot be mapped to an edition name, so it always matches.
fn edition_matches(want: string, have: string) -> bool {
    if is_product_key(want) { return true }
    let w = want.to_lower()
    let h = have.to_lower()
    if w == "developer" { return h.contains("developer") }
    if w == "express" { return h.contains("express") }
    if w == "evaluation" { return h.contains("evaluation") }
    if w == "enterprisecore" { return h.contains("core-based") }
    if w == "enterprise" { return h.starts_with("enterprise edition") && !h.contains("core-based") }
    if w == "standard" { return h.starts_with("standard edition") }
    if w == "web" { return h.starts_with("web") }
    h.starts_with(w)
}

// Connection params for the T-SQL comparisons: sa on Linux (the only login
// mssql-conf creates), integrated auth on Windows.
fn conn(params: Value) -> Result[Value, string] {
    let inst = instance_name(params)?
    if sys::family() == "windows" {
        return Ok(Value::Map(#{ "instance": Value::String(inst) }))
    }
    Ok(Value::Map(#{
        "sql_user": Value::String("sa"),
        "sql_password": Value::String(common::param_str(params, "sa_password", ""))
    }))
}

fn tools_installed() -> bool {
    let bin = common::sqlcmd_bin()
    if bin != "sqlcmd" { return true }
    if sys::family() == "windows" {
        if let Ok(out) = shell::run("where.exe sqlcmd", Value::Null) { return out.success }
        return false
    }
    if let Ok(out) = shell::bash("command -v sqlcmd", Value::Null) { return out.success }
    false
}

// The T-SQL-side drift shared by both platforms: collation and edition.
// Collation cannot change in place (it needs the system databases rebuilt),
// so a mismatch is an error rather than something to apply.
fn sql_drift(params: Value) -> Result[List[string], string] {
    let c = conn(params)?
    let row = common::run_scalar(c, "SELECT CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) + N'|' + CAST(SERVERPROPERTY('Edition') AS nvarchar(128));")?
    let f = row.split("|")
    let have_coll = f.get(0).unwrap_or("")
    let have_ed = f.get(1).unwrap_or("")
    let coll = common::param_str(params, "collation", "")
    if coll != "" && coll.to_lower() != have_coll.to_lower() {
        return Err("the instance has collation '" + have_coll + "', not '" + coll +
            "'; the server collation only changes by rebuilding the system databases, which config-weave does not do")
    }
    let out = []
    let ed = edition(params)?
    if !edition_matches(ed, have_ed) {
        if sys::family() == "windows" {
            return Err("the instance is '" + have_ed + "', not " + ed +
                "; on Windows an edition change is a setup.exe /ACTION=EditionUpgrade run with a product key, which config-weave does not do")
        }
        out.push("edition")
    }
    Ok(out)
}

// ==== Windows ================================================================

// --- features and the components they install ---

// The Instance Names key a feature code is registered under: SQL for the
// engine and its sub-features, OLAP for Analysis Services, RS for the
// Reporting Services feature of SQL Server 2016 and older. "" for shared
// features (IS, MDS, client tools and so on), which belong to no instance.
fn component_of(feature: string) -> string {
    let f = feature.to_upper()
    if ["SQL", "SQLENGINE", "REPLICATION", "FULLTEXT", "DQ", "POLYBASE", "POLYBASECORE", "POLYBASEJAVA",
        "ADVANCEDANALYTICS", "SQL_INST_MR", "SQL_INST_MPY", "SQL_INST_JAVA", "AZUREEXTENSION"].contains(f) { return "SQL" }
    if f == "AS" { return "OLAP" }
    if f == "RS" { return "RS" }
    ""
}

fn feature_list(params: Value) -> Result[List[string], string] {
    let raw = common::param_str(params, "features", "SQLENGINE")
    if !common::only_chars(raw, ",_ ") { return Err("invalid 'features' '" + raw + "' (comma separated feature codes)") }
    let out = common::csv(raw).map(|f| f.to_upper())
    if out.is_empty() { return Err("'features' must name at least one feature") }
    Ok(out)
}

// The instance components the features install, in SQL, OLAP, RS order.
fn components(params: Value) -> Result[List[string], string] {
    let fs = feature_list(params)?
    let out = []
    for c in ["SQL", "OLAP", "RS"] {
        if fs.any(|f| component_of(f) == c) { out.push(c) }
    }
    if out.is_empty() {
        return Err("'features' names no instance feature (SQLENGINE, AS or RS), so there is no instance to detect; shared features install with one of them")
    }
    Ok(out)
}

fn component_label(c: string) -> string {
    if c == "SQL" { "the database engine" } else if c == "OLAP" { "Analysis Services" } else { "Reporting Services" }
}

fn win_has(inst: string, c: string) -> Result[bool, string] {
    Ok(common::win_component_id(c, inst)? != "")
}

// The requested components that are installed, and those that are not.
fn win_split_components(params: Value) -> Result[List[List[string]], string] {
    let inst = instance_name(params)?
    let have = []
    let missing = []
    for c in components(params)? {
        if win_has(inst, c)? { have.push(c) } else { missing.push(c) }
    }
    Ok([have, missing])
}

fn win_server_key(inst: string) -> Result[string, string] {
    Ok("HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\" + common::win_instance_id(inst)? + "\\MSSQLServer")
}

fn norm_dir(p: string) -> string {
    let t = p.trim().to_lower()
    if t.ends_with("\\") { t.slice(0, t.len() - 1) } else { t }
}

fn reg_value(key: string, name: string) -> Result[Option[Value], string] { registry::read(key, name) }

// Registry-backed settings that differ, as [name, key, value-name, kind, value].
fn win_reg_drift(params: Value) -> Result[List[List[string]], string] {
    let inst = instance_name(params)?
    let srv = win_server_key(inst)?
    let out = []
    let mode = if want_sql_auth(params)? { 2 } else { 1 }
    let have_mode = if let Some(v) = reg_value(srv, "LoginMode")? { v.as_int().unwrap_or(0) } else { 0 }
    if have_mode != mode { out.push(["security_mode", srv, "LoginMode", "dword", str(mode)]) }
    let tcp_key = srv + "\\SuperSocketNetLib\\Tcp"
    let tcp = if common::param_bool(params, "tcp_enabled", true) { 1 } else { 0 }
    let have_tcp = if let Some(v) = reg_value(tcp_key, "Enabled")? { v.as_int().unwrap_or(-1) } else { -1 }
    if have_tcp != tcp { out.push(["tcp_enabled", tcp_key, "Enabled", "dword", str(tcp)]) }
    for d in [["data_dir", "DefaultData"], ["log_dir", "DefaultLog"], ["backup_dir", "BackupDirectory"]] {
        let want = common::param_str(params, d[0], "")
        if want != "" {
            let have = if let Some(v) = reg_value(srv, d[1])? { v.as_string().unwrap_or("") } else { "" }
            if norm_dir(have) != norm_dir(want) { out.push([d[0], srv, d[1], "sz", want]) }
        }
    }
    Ok(out)
}

fn sysadmin_accounts(params: Value) -> List[string] {
    common::csv(common::param_str(params, "sql_sysadmin_accounts", "BUILTIN\\Administrators"))
}

fn as_sysadmin_accounts(params: Value) -> List[string] {
    common::csv(common::param_str(params, "as_sysadmin_accounts", "BUILTIN\\Administrators"))
}

// as_server_mode as setup's ASSERVERMODE and msmdsrv.ini's DeploymentMode.
fn as_mode(params: Value) -> Result[List[string], string] {
    let m = common::param_str(params, "as_server_mode", "multidimensional")
    if m == "multidimensional" { return Ok(["MULTIDIMENSIONAL", "0"]) }
    if m == "powerpivot" { return Ok(["POWERPIVOT", "1"]) }
    if m == "tabular" { return Ok(["TABULAR", "2"]) }
    Err("invalid 'as_server_mode' value '" + m + "' (expected :multidimensional, :tabular or :powerpivot)")
}

// The Analysis Services directory params: [param, setup option, msmdsrv.ini element].
fn as_dirs() -> List[List[string]] {
    [["as_data_dir", "ASDATADIR", "DataDir"], ["as_log_dir", "ASLOGDIR", "LogDir"],
     ["as_temp_dir", "ASTEMPDIR", "TempDir"], ["as_backup_dir", "ASBACKUPDIR", "BackupDir"]]
}

// msmdsrv.ini settings that differ, as [param, element path, wanted value].
// The server mode and the data directory cannot change on an existing
// instance (the mode is fixed by setup; moving DataDir orphans every
// database stored under the old one), so those are errors.
fn as_ini_drift(params: Value) -> Result[List[List[string]], string] {
    let inst = instance_name(params)?
    let ini = ssas::ini_path(inst)?
    let root = "/ConfigurationSettings/"
    let xps = [root + "DeploymentMode", root + "CollationName"]
    for d in as_dirs() { xps.push(root + d[2]) }
    let have = xmlfile::read_values(ini, xps)?
    let get = |xp: string| -> string { if let Some(o) = have.get(xp) { o.unwrap_or("") } else { "" } }
    let mode = as_mode(params)?
    let have_mode = get(root + "DeploymentMode").trim()
    let have_mode_n = if have_mode == "" { "0" } else { have_mode }
    if have_mode_n != mode[1] {
        let names = #{ "0": "multidimensional", "1": "powerpivot", "2": "tabular" }
        let label = names.get(have_mode_n).unwrap_or("DeploymentMode " + have_mode_n)
        return Err("Analysis Services instance " + inst + " runs in " + label + " mode, not " +
            common::param_str(params, "as_server_mode", "multidimensional") + "; the server mode is fixed by setup, so it only changes by reinstalling the instance")
    }
    let out = []
    let coll = common::param_str(params, "as_collation", "")
    common::check_collation(coll)?
    if coll != "" && coll.to_lower() != get(root + "CollationName").trim().to_lower() {
        out.push(["as_collation", root + "CollationName", coll])
    }
    for d in as_dirs() {
        let want = common::param_str(params, d[0], "")
        if want == "" { continue }
        let have_dir = get(root + d[2])
        if norm_dir(have_dir) == norm_dir(want) { continue }
        if d[0] == "as_data_dir" {
            return Err("Analysis Services instance " + inst + " keeps its data in '" + have_dir + "', not '" + want +
                "'; config-weave does not move DataDir, because databases under the old directory would no longer be found")
        }
        out.push([d[0], root + d[2], want])
    }
    Ok(out)
}

fn as_drift(params: Value) -> Result[List[string], string] {
    let inst = instance_name(params)?
    let out = as_ini_drift(params)?.map(|d| d[0])
    let missing = ssas::missing_admins(inst, as_sysadmin_accounts(params))?
    if !missing.is_empty() { out.push("as_sysadmin_accounts") }
    Ok(out)
}

fn as_apply(params: Value) -> Result[unit, string] {
    let inst = instance_name(params)?
    let ini = as_ini_drift(params)?
    for d in ini {
        if d[0].ends_with("_dir") && !fs::is_dir(d[2]) {
            return Err("'" + d[0] + "' directory '" + d[2] + "' does not exist; create it, writable by " + ssas::service_name(inst) + ", first")
        }
    }
    if !ini.is_empty() {
        let changed = xmlfile::write_values(ssas::ini_path(inst)?, ini.map(|d| [d[1], d[2]]))?
        if changed { ssas::restart(inst)? }
    }
    ssas::add_admins(inst, ssas::missing_admins(inst, as_sysadmin_accounts(params))?)
}

// T-SQL-side drift on Windows: the sysadmin accounts, and sa under mixed mode.
fn win_tsql_drift(params: Value) -> Result[List[string], string] {
    let checks = []
    for a in sysadmin_accounts(params) {
        checks.push(["sysadmin:" + a.replace(" ", "_"), "IS_SRVROLEMEMBER(N'sysadmin', " + common::tsql_lit(a) + ") = 1"])
    }
    if want_sql_auth(params)? {
        let sa = common::param_str(params, "sa_password", "")
        checks.push(["sa_password", "EXISTS (SELECT 1 FROM sys.sql_logins WHERE sid = 0x01 AND is_disabled = 0 AND PWDCOMPARE(" + common::tsql_lit(sa) + ", password_hash) = 1)"])
    }
    let Some(d) = common::drift(conn(params)?, "", checks)? else { return Ok(["instance"]) }
    Ok(d)
}

fn win_check(params: Value) -> Result[CheckResult, string] {
    let inst = instance_name(params)?
    as_mode(params)?
    let split = win_split_components(params)?
    let have = split[0]
    if have.is_empty() { return Ok(CheckResult::NotConfigured) }
    if want_sql_auth(params)? && common::param_str(params, "sa_password", "") == "" { return Err("security_mode = :sql requires an 'sa_password'") }
    let drift = split[1].map(|c| "features:" + c)
    if have.contains("SQL") {
        if common::param_bool(params, "install_tools", true) && !tools_installed() { drift.push("install_tools") }
        for r in win_reg_drift(params)? { drift.push(r[0]) }
        if tools_installed() {
            for d in sql_drift(params)? { drift.push(d) }
            for d in win_tsql_drift(params)? { drift.push(d) }
        } else {
            return Err("sqlcmd is not installed, so the instance's collation, edition and logins cannot be compared; set install_tools = true or install sqlcmd")
        }
    }
    if have.contains("OLAP") {
        for d in as_drift(params)? { drift.push(d) }
    }
    if drift.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("instance " + inst + " differs in: " + drift.join(", "))
    Ok(CheckResult::NotConfigured)
}

fn win_pid(edition: string) -> string {
    if edition == "" || edition == "Developer" || edition == "Evaluation" || edition == "Express" { "" } else { edition }
}

fn ini_value(key: string, v: string) -> Result[string, string] {
    common::no_newlines(key, v)?
    // setup.exe has no escape for an embedded double quote.
    if v.contains("\"") { return Err("'" + key + "' contains a double quote, which setup.exe cannot accept") }
    Ok("\"" + v + "\"")
}

// The ConfigurationFile.ini for an install. It carries the sa password, so it
// lives in a directory only SYSTEM and Administrators can read, which is
// removed after setup runs.
//
// `features` is what to install: the whole list for a new instance, or only
// the features of the components still missing from an existing one. The
// engine options go in only when the engine is being installed, the
// Analysis Services ones only with AS (an AS-only setup rejects nothing, but
// has no use for SQLSYSADMINACCOUNTS).
fn win_config_ini(params: Value, features: List[string]) -> Result[string, string] {
    let inst = instance_name(params)?
    let engine = features.any(|f| component_of(f) == "SQL")
    let olap = features.any(|f| component_of(f) == "OLAP")
    let lines = [
        "[OPTIONS]",
        "ACTION=\"Install\"",
        "QUIET=\"True\"",
        "IACCEPTSQLSERVERLICENSETERMS=\"True\"",
        "UPDATEENABLED=\"False\"",
        "FEATURES=" + features.join(","),
        "INSTANCENAME=" + ini_value("instance", inst)?
    ]
    if olap {
        lines.push("ASSERVERMODE=\"" + as_mode(params)?[0] + "\"")
        let quoted = []
        for a in as_sysadmin_accounts(params) { quoted.push(ini_value("as_sysadmin_accounts", a)?) }
        if quoted.is_empty() { return Err("Analysis Services setup needs at least one account in 'as_sysadmin_accounts'") }
        lines.push("ASSYSADMINACCOUNTS=" + quoted.join(" "))
        let ascoll = common::param_str(params, "as_collation", "")
        common::check_collation(ascoll)?
        if ascoll != "" { lines.push("ASCOLLATION=\"" + ascoll + "\"") }
        for d in as_dirs() {
            let v = common::param_str(params, d[0], "")
            if v != "" { lines.push(d[1] + "=" + ini_value(d[0], v)?) }
        }
    }
    let pid = win_pid(edition(params)?)
    if pid != "" { lines.push("PID=" + ini_value("edition", pid)?) }
    if !engine { return Ok(lines.join("\r\n") + "\r\n") }
    lines.push("TCPENABLED=\"" + (if common::param_bool(params, "tcp_enabled", true) { "1" } else { "0" }) + "\"")
    let accounts = sysadmin_accounts(params)
    if !accounts.is_empty() {
        let quoted = []
        for a in accounts { quoted.push(ini_value("sql_sysadmin_accounts", a)?) }
        lines.push("SQLSYSADMINACCOUNTS=" + quoted.join(" "))
    }
    if want_sql_auth(params)? {
        let sa = common::param_str(params, "sa_password", "")
        if sa == "" { return Err("security_mode = :sql requires an 'sa_password'") }
        lines.push("SECURITYMODE=\"SQL\"")
        lines.push("SAPWD=" + ini_value("sa_password", sa)?)
    }
    let coll = common::param_str(params, "collation", "")
    common::check_collation(coll)?
    if coll != "" { lines.push("SQLCOLLATION=\"" + coll + "\"") }
    for d in [["data_dir", "SQLUSERDBDIR"], ["log_dir", "SQLUSERDBLOGDIR"], ["backup_dir", "SQLBACKUPDIR"]] {
        let v = common::param_str(params, d[0], "")
        if v != "" { lines.push(d[1] + "=" + ini_value(d[0], v)?) }
    }
    Ok(lines.join("\r\n") + "\r\n")
}

// Runs setup.exe with `args`; 3010 means it wants a reboot. A URL is
// downloaded (verified, see common::download_verified) for the run and
// deleted afterwards.
fn win_run_setup(params: Value, args: string) -> Result[ApplyResult, string] {
    let setup = common::require(params, "setup_path")?
    let got = common::local_installer(setup, "sqlserver-setup.exe", "")?
    let extra = common::param_str(params, "extra_args", "")
    let all = if extra != "" { args + " " + extra } else { args }
    let script = "$c = (Start-Process -FilePath " + common::ps_q(got[0]) + " -ArgumentList " + common::ps_q(all) + " -Wait -PassThru).ExitCode; exit $c"
    let opts = Value::Map(#{ "timeout": Value::Int(common::param_int(params, "install_timeout", 3600)) })
    let res = shell::powershell(script, opts)
    if got[1] != "" { fs::delete_dir(got[1]).unwrap_or(()) }
    let out = res?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(common::cmd_error("setup.exe", out)) }
    Ok(ApplyResult::Success)
}

fn win_install(params: Value, features: List[string]) -> Result[ApplyResult, string] {
    let inst = instance_name(params)?
    let cfg = common::param_str(params, "config_file", "")
    if cfg != "" {
        // A full ConfigurationFile.ini wins: pass it through and only add the EULA.
        log::info("running SQL Server setup for instance " + inst + " from " + cfg)
        return win_run_setup(params, "/Q /IACCEPTSQLSERVERLICENSETERMS /ConfigurationFile=" + ini_value("config_file", cfg)?)
    }
    let ini = win_config_ini(params, features)?
    let dir = fs::temp_dir()?
    let acl = shell::run("icacls " + common::q(dir) + " /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F", Value::Null)?
    if !acl.success {
        fs::delete_dir(dir)?
        return Err(common::cmd_error("icacls", acl))
    }
    let file = path::join(dir, "ConfigurationFile.ini")
    fs::write(file, ini)?
    log::info("running SQL Server setup for instance " + inst + " (" + features.join(",") + ")")
    let res = win_run_setup(params, "/ConfigurationFile=\"" + file + "\"")
    let cleanup = fs::delete_dir(dir)
    let r = res?
    cleanup?
    Ok(r)
}

fn win_install_tools(params: Value) -> Result[unit, string] {
    let url = common::param_str(params, "tools_msi_url", "")
    let pick = if url != "" { "$url = " + common::ps_q(url) + "; " } else {
        "$rel = Invoke-RestMethod -UseBasicParsing https://api.github.com/repos/microsoft/go-sqlcmd/releases/latest; " +
            "$a = $rel.assets | Where-Object {{ $_.name -like '*amd64.msi' }} | Select-Object -First 1; " +
            "if (-not $a) {{ throw 'no go-sqlcmd MSI in the latest release' }}; $url = $a.browser_download_url; "
    }
    let script = "$ErrorActionPreference = 'Stop'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " +
        pick +
        "$msi = Join-Path ([IO.Path]::GetTempPath()) 'go-sqlcmd.msi'; " +
        "Invoke-WebRequest -UseBasicParsing $url -OutFile $msi; " +
        "$p = Start-Process msiexec.exe -ArgumentList '/i', $msi, '/qn', '/norestart' -Wait -PassThru; " +
        "Remove-Item $msi -Force; " +
        "if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {{ throw ('msiexec exited ' + $p.ExitCode) }}"
    log::info("installing go-sqlcmd")
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(common::cmd_error("installing go-sqlcmd", out)) }
    Ok(())
}

fn win_apply(params: Value) -> Result[ApplyResult, string] {
    let inst = instance_name(params)?
    let split = win_split_components(params)?
    let wanted = components(params)?
    let engine = wanted.contains("SQL")
    if !split[1].is_empty() {
        // A new instance gets every feature; an existing one only the
        // features of its missing components (shared features were
        // installed with it).
        let all = feature_list(params)?
        let features = if split[0].is_empty() { all } else { all.filter(|f| split[1].contains(component_of(f))) }
        if !split[0].is_empty() && common::param_str(params, "config_file", "") != "" {
            return Err("instance " + inst + " lacks " + split[1].map(|c| component_label(c)).join(" and ") +
                ", but config_file replaces the generated setup options, so config-weave cannot add only those features; add them to the instance yourself")
        }
        let r = win_install(params, features)?
        if r == ApplyResult::RebootRequired {
            if engine && common::param_bool(params, "install_tools", true) && !tools_installed() { win_install_tools(params)? }
            return Ok(r)
        }
    }
    if wanted.contains("OLAP") { as_apply(params)? }
    if !engine { return Ok(ApplyResult::Success) }
    if common::param_bool(params, "install_tools", true) && !tools_installed() { win_install_tools(params)? }

    // Registry settings take effect when the engine restarts.
    let reg = win_reg_drift(params)?
    for r in reg {
        let v = if r[3] == "dword" { Value::Int(r[4].parse_int().unwrap_or(0)) } else { Value::String(r[4]) }
        registry::write(r[1], r[2], v, r[3])?
    }
    if !reg.is_empty() {
        log::info("restarting " + common::win_service_name(inst) + " to apply " + reg.map(|r| r[0]).join(", "))
        common::win_restart_engine(inst)?
        common::wait_for_engine(conn(params)?, 120)?
    }

    sql_drift(params)?
    let batch = sysadmin_accounts(params).fold("", |acc, a|
        acc + "IF SUSER_ID(" + common::tsql_lit(a) + ") IS NULL CREATE LOGIN " + common::tsql_id(a) + " FROM WINDOWS; " +
            "IF IS_SRVROLEMEMBER(N'sysadmin', " + common::tsql_lit(a) + ") <> 1 ALTER SERVER ROLE [sysadmin] ADD MEMBER " + common::tsql_id(a) + "; ")
    let sa = if want_sql_auth(params)? {
        let pw = common::param_str(params, "sa_password", "")
        "DECLARE @sa sysname = SUSER_SNAME(0x01); DECLARE @q nvarchar(max) = " +
            "N'ALTER LOGIN ' + QUOTENAME(@sa) + N' WITH PASSWORD = ' + QUOTENAME(" + common::tsql_lit(pw) + ", '''') + N'; ALTER LOGIN ' + QUOTENAME(@sa) + N' ENABLE;'; " +
            "IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE sid = 0x01 AND is_disabled = 0 AND PWDCOMPARE(" + common::tsql_lit(pw) + ", password_hash) = 1) EXEC (@q); "
    } else { "" }
    if batch + sa != "" { common::run_exec(conn(params)?, batch + sa)? }
    Ok(ApplyResult::Success)
}

fn win_remove(params: Value) -> Result[ApplyResult, string] {
    let inst = instance_name(params)?
    let features = feature_list(params)?.join(",")
    log::info("uninstalling " + features + " from SQL Server instance " + inst)
    win_run_setup(params, "/Q /ACTION=Uninstall /INSTANCENAME=" + ini_value("instance", inst)? + " /FEATURES=" + features)
}

// ==== Linux ==================================================================

fn linux_installed() -> Result[bool, string] {
    if !fs::exists("/opt/mssql/bin/sqlservr") { return Ok(false) }
    let out = shell::bash("systemctl is-active --quiet mssql-server || systemctl is-enabled --quiet mssql-server", Value::Null)?
    Ok(out.success)
}

fn linux_manager() -> string {
    if fs::exists("/usr/bin/apt-get") { return "apt" }
    if fs::exists("/usr/bin/dnf5") { return "dnf5" }
    if fs::exists("/usr/bin/dnf") { return "dnf" }
    if fs::exists("/usr/bin/yum") { return "yum" }
    if fs::exists("/usr/bin/zypper") { return "zypper" }
    "unknown"
}

fn os_release_field(text: string, key: string) -> string {
    for line in text.split("\n") {
        if line.starts_with(key + "=") {
            return line.slice(key.len() + 1, line.len()).trim().replace("\"", "").replace("'", "")
        }
    }
    ""
}

// The packages.microsoft.com/config path for this distribution, read from
// /etc/os-release: ubuntu/<version>, rhel/<major> or sles/<major>.
fn linux_repo_path() -> Result[string, string] {
    let Ok(text) = fs::read("/etc/os-release") else { return Err("cannot read /etc/os-release; set 'repo_url'") }
    let id = os_release_field(text, "ID")
    let like = os_release_field(text, "ID_LIKE")
    let ver = os_release_field(text, "VERSION_ID")
    let major = ver.split(".").get(0).unwrap_or("")
    if ver == "" { return Err("no VERSION_ID in /etc/os-release; set 'repo_url'") }
    if id == "ubuntu" { return Ok("ubuntu/" + ver) }
    if id == "rhel" || like.contains("rhel") { return Ok("rhel/" + major) }
    if id == "sles" || id == "opensuse-leap" || like.contains("suse") { return Ok("sles/" + major) }
    Err("Microsoft publishes no SQL Server repository for '" + id + " " + ver + "'; set 'repo_url' (and 'tools_repo_url')")
}

fn linux_version(params: Value) -> Result[string, string] {
    let v = common::param_str(params, "version", "2022")
    if v.parse_int().is_none() { return Err("invalid 'version' '" + v + "' (a SQL Server year such as 2022)") }
    Ok(v)
}

// Fetches the repo definitions for the server and the tools into place.
fn linux_add_repos(params: Value, m: string, want_tools: bool) -> Result[unit, string] {
    let version = linux_version(params)?
    let repo = common::param_str(params, "repo_url", "")
    let tools_repo = common::param_str(params, "tools_repo_url", "")
    let need_path = repo == "" || (want_tools && tools_repo == "")
    let base = if need_path { "https://packages.microsoft.com/config/" + linux_repo_path()? + "/" } else { "" }
    let ext = if m == "apt" { ".list" } else { ".repo" }
    let server_url = if repo != "" { repo } else { base + "mssql-server-" + version + ext }
    let tools_url = if tools_repo != "" { tools_repo } else { base + "prod" + ext }
    let script = if m == "apt" {
        "set -e; " +
            "curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --batch --yes --dearmor -o /usr/share/keyrings/microsoft-prod.gpg; " +
            "cp /usr/share/keyrings/microsoft-prod.gpg /etc/apt/trusted.gpg.d/microsoft-prod.gpg; " +
            "curl -fsSL " + common::q(server_url) + " -o /etc/apt/sources.list.d/mssql-server.list; " +
            (if want_tools { "curl -fsSL " + common::q(tools_url) + " -o /etc/apt/sources.list.d/msprod.list; " } else { "" }) +
            "apt-get update"
    } else if m == "dnf5" || m == "dnf" || m == "yum" {
        "set -e; " +
            "curl -fsSL " + common::q(server_url) + " -o /etc/yum.repos.d/mssql-server.repo; " +
            (if want_tools { "curl -fsSL " + common::q(tools_url) + " -o /etc/yum.repos.d/msprod.repo; " } else { "" })
    } else if m == "zypper" {
        // addrepo fails when the alias exists, so only add what is missing.
        "set -e; " +
            "zypper lr mssql-server >/dev/null 2>&1 || zypper --non-interactive addrepo -fc " + common::q(server_url) + " mssql-server; " +
            (if want_tools { "zypper lr msprod >/dev/null 2>&1 || zypper --non-interactive addrepo -fc " + common::q(tools_url) + " msprod; " } else { "" }) +
            "zypper --non-interactive --gpg-auto-import-keys refresh"
    } else {
        return Err("unsupported Linux package manager for SQL Server; use apt, dnf, yum or zypper")
    }
    let out = shell::bash(script, Value::Null)?
    if !out.success { return Err(common::cmd_error("adding the Microsoft repositories", out)) }
    Ok(())
}

fn linux_install_pkgs(m: string, pkgs: string) -> Result[unit, string] {
    let cmd = if m == "apt" {
        "DEBIAN_FRONTEND=noninteractive apt-get install -y " + pkgs
    } else if m == "zypper" {
        "zypper --non-interactive --gpg-auto-import-keys install " + pkgs
    } else {
        m + " install -y " + pkgs
    }
    let out = shell::bash(cmd, Value::Map(#{ "env": Value::Map(#{ "ACCEPT_EULA": Value::String("Y") }) }))?
    if !out.success { return Err(common::cmd_error("installing " + pkgs, out)) }
    Ok(())
}

// The installed major version as a SQL Server year, or "" if unknown.
fn linux_installed_year() -> Result[string, string] {
    let out = shell::bash("dpkg-query -W -f='${{Version}}' mssql-server 2>/dev/null || rpm -q --qf '%{{VERSION}}' mssql-server 2>/dev/null", Value::Null)?
    let major = out.stdout.trim().split(".").get(0).unwrap_or("")
    if major == "14" { return Ok("2017") }
    if major == "15" { return Ok("2019") }
    if major == "16" { return Ok("2022") }
    if major == "17" { return Ok("2025") }
    Ok("")
}

// True when sa can log in with sa_password.
fn linux_sa_ok(params: Value) -> Result[bool, string] {
    match common::run_scalar(conn(params)?, "SELECT 1;") {
        Ok(_) => Ok(true),
        Err(e) => {
            if e.contains("Login failed") { return Ok(false) }
            Err(e)
        }
    }
}

fn linux_check(params: Value) -> Result[CheckResult, string] {
    if common::param_str(params, "sa_password", "") == "" { return Err("the Linux engine requires an 'sa_password'") }
    if !linux_installed()? { return Ok(CheckResult::NotConfigured) }
    let want = linux_version(params)?
    let have = linux_installed_year()?
    if have != "" && have != want {
        return Err("SQL Server " + have + " is installed, not " + want +
            "; a major version upgrade is one-way and needs a backup first, so config-weave leaves it to you")
    }
    let drift = []
    if common::param_bool(params, "install_tools", true) && !tools_installed() { drift.push("install_tools") }
    if !linux_sa_ok(params)? {
        drift.push("sa_password")
    } else if tools_installed() {
        for d in sql_drift(params)? { drift.push(d) }
    }
    if drift.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("mssql-server differs in: " + drift.join(", "))
    Ok(CheckResult::NotConfigured)
}

// Runs an mssql-conf command that needs the service stopped.
fn linux_conf_offline(params: Value, what: string, cmd: string) -> Result[unit, string] {
    let env = Value::Map(#{ "env": Value::Map(#{
        "ACCEPT_EULA": Value::String("Y"),
        "MSSQL_PID": Value::String(edition(params)?),
        "MSSQL_SA_PASSWORD": Value::String(common::param_str(params, "sa_password", ""))
    }), "timeout": Value::Int(common::param_int(params, "install_timeout", 3600)) })
    log::info("stopping mssql-server to " + what)
    let out = shell::bash("set -e; systemctl stop mssql-server; /opt/mssql/bin/mssql-conf -n " + cmd + "; systemctl start mssql-server", env)?
    if !out.success { return Err(common::cmd_error("mssql-conf " + cmd, out)) }
    common::wait_for_engine(conn(params)?, 120)
}

fn linux_apply(params: Value) -> Result[ApplyResult, string] {
    let sa = common::param_str(params, "sa_password", "")
    if sa == "" { return Err("the Linux engine requires an 'sa_password'") }
    let coll = common::param_str(params, "collation", "")
    common::check_collation(coll)?
    let ed = edition(params)?
    let tools = common::param_bool(params, "install_tools", true)
    let m = linux_manager()
    if m == "unknown" { return Err("could not detect a supported Linux package manager") }

    let need_server = !fs::exists("/opt/mssql/bin/sqlservr")
    let need_tools = tools && !tools_installed()
    if need_server || need_tools { linux_add_repos(params, m, need_tools)? }
    if need_server { linux_install_pkgs(m, "mssql-server")? }
    if need_tools { linux_install_pkgs(m, "mssql-tools18")? }

    if !linux_installed()? {
        // MSSQL_COLLATION is read by setup itself, so the instance is created
        // with it rather than changed afterwards.
        let env = Value::Map(#{ "env": Value::Map(#{
            "ACCEPT_EULA": Value::String("Y"),
            "MSSQL_PID": Value::String(ed),
            "MSSQL_SA_PASSWORD": Value::String(sa),
            "MSSQL_COLLATION": Value::String(coll)
        }), "timeout": Value::Int(common::param_int(params, "install_timeout", 3600)) })
        log::info("running mssql-conf setup")
        let setup = shell::bash("/opt/mssql/bin/mssql-conf -n setup", env)?
        if !setup.success { return Err(common::cmd_error("mssql-conf setup", setup)) }
        let svc = shell::bash("systemctl enable --now mssql-server", Value::Null)?
        if !svc.success { return Err(common::cmd_error("systemctl enable --now mssql-server", svc)) }
        common::wait_for_engine(conn(params)?, 120)?
        return Ok(ApplyResult::Success)
    }

    if !linux_sa_ok(params)? { linux_conf_offline(params, "reset the sa password", "set-sa-password")? }
    if sql_drift(params)?.contains("edition") { linux_conf_offline(params, "change the edition to " + ed, "set-edition")? }
    Ok(ApplyResult::Success)
}

fn linux_remove(params: Value) -> Result[ApplyResult, string] {
    let m = linux_manager()
    let cmd = if m == "apt" {
        "DEBIAN_FRONTEND=noninteractive apt-get remove -y mssql-server"
    } else if m == "zypper" {
        "zypper --non-interactive remove mssql-server"
    } else if m == "dnf5" || m == "dnf" || m == "yum" {
        m + " remove -y mssql-server"
    } else {
        return Err("unsupported Linux package manager")
    }
    log::info("removing the mssql-server package")
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(common::cmd_error("removing mssql-server", out)) }
    Ok(ApplyResult::Success)
}

// ==== entry points ===========================================================

fn check(params: Value) -> Result[CheckResult, string] {
    let inst = instance_name(params)?
    want_sql_auth(params)?
    edition(params)?
    common::check_collation(common::param_str(params, "collation", ""))?
    if !common::want_present(params)? {
        // existence probe only: on Linux the bare engine binary (even
        // without a configured service) still means work to do
        let present = if sys::family() == "windows" { !win_split_components(params)?[0].is_empty() } else { fs::exists("/opt/mssql/bin/sqlservr") }
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if sys::family() == "windows" { win_check(params) } else { linux_check(params) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if !common::want_present(params)? {
        if sys::family() == "windows" { return win_remove(params) }
        return linux_remove(params)
    }
    if sys::family() == "windows" { win_apply(params) } else { linux_apply(params) }
}
