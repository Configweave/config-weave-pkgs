use value
use sys
use env
use log
use registry
use common
use mds

// The Master Data Services web application: an IIS site serving the MDS
// install's WebApplication folder, with its own application pool, pointed at
// an MDS database, as MDS Configuration Manager creates it (lib/mds.ws).
// SQL Server 2019 and older only.

struct Want {
    site: string,
    port: int,
    pool: string,
    identity: string,
    password: string,
    database: string,
    server: string,
    url: string,
    dir: string,
}

// The IIS role services Microsoft lists as MDS prerequisites on Windows Server.
fn prerequisites() -> List[string] {
    ["Web-Server", "Web-Default-Doc", "Web-Dir-Browsing", "Web-Http-Errors", "Web-Static-Content", "Web-Http-Logging",
     "Web-Request-Monitor", "Web-Stat-Compression", "Web-Filtering", "Web-Windows-Auth", "Web-Net-Ext45", "Web-Asp-Net45",
     "Web-ISAPI-Ext", "Web-ISAPI-Filter", "NET-WCF-HTTP-Activation45", "WAS-Process-Model", "WAS-Config-APIs", "Web-Mgmt-Console"]
}

fn marker_key(site: string) -> string { "HKLM\\SOFTWARE\\config-weave\\mssql\\mds_web_application\\" + site }

fn check_name(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("'" + key + "' must not be empty") }
    common::no_newlines(key, v)?
    for bad in ["'", "\"", "/", "\\", "?", ";", ":", "@", "&", "=", "+", "$", ",", "|", "<", ">", "*", "[", "]"] {
        if v.contains(bad) { return Err("'" + key + "' '" + v + "' contains '" + bad + "', which IIS does not allow in a name") }
    }
    Ok(())
}

fn want(params: Value) -> Result[Want, string] {
    if sys::family() != "windows" { return Err("mssql.mds_web_application is Windows only") }
    let site = common::require(params, "site")?
    check_name("site", site)?
    let pool = common::param_str(params, "app_pool", "MDS Application Pool")
    check_name("app_pool", pool)?
    let port = common::param_int(params, "port", 80)
    if port < 1 || port > 65535 { return Err("invalid 'port' " + str(port)) }
    let identity = common::param_str(params, "identity", "")
    common::no_newlines("identity", identity)?
    let database = common::param_str(params, "database", "")
    if database != "" && !common::only_chars(database, "_-$") { return Err("invalid 'database' '" + database + "' (letters, digits, _, - and $)") }
    let server = common::param_str(params, "server", "localhost")
    if server == "" || server.contains("'") || server.contains(";") { return Err("invalid 'server' '" + server + "'") }
    let url0 = common::param_str(params, "url", "")
    common::no_newlines("url", url0)?
    let url = if url0 != "" { url0 } else { "http://" + env::hostname() + ":" + str(port) }
    let dir = mds::locate("mds_web_application", common::param_str(params, "mds_version", ""))?
    Ok(Want { site: site, port: port, pool: pool, identity: identity, password: common::param_str(params, "password", ""),
        database: database, server: server, url: url, dir: dir })
}

// The site's state as IIS, web.config and the local MDS_ServiceAccounts
// group have it.
fn state(w: Want) -> Result[Value, string] {
    let body = "[void][Reflection.Assembly]::LoadWithPartialName('Microsoft.Web.Administration')\n" +
        "$missing = @()\n" +
        "if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {{ $missing = @(Get-WindowsFeature -Name " +
        "@(" + prerequisites().map(|f| common::ps_q(f)).join(", ") + ") | Where-Object {{ -not $_.Installed }} | ForEach-Object {{ $_.Name }}) }}\n" +
        "$o = [ordered]@{{ missing = @($missing); exists = $false; path = $mdsPath }}\n" +
        "if ($missing.Count -eq 0) {{\n" +
        "  $sm = New-Object Microsoft.Web.Administration.ServerManager\n" +
        "  $s = $sm.Sites[" + common::ps_q(w.site) + "]\n" +
        "  if ($s) {{\n" +
        "    $app = $s.Applications['/']\n" +
        "    $o.exists = $true\n" +
        "    $o.physical = [string]$app.VirtualDirectories['/'].PhysicalPath\n" +
        "    $o.app_pool = [string]$app.ApplicationPoolName\n" +
        "    $o.bindings = @($s.Bindings | ForEach-Object {{ $_.Protocol + ' ' + $_.BindingInformation }})\n" +
        "    $p = $sm.ApplicationPools[" + common::ps_q(w.pool) + "]\n" +
        "    $o.pool_exists = [bool]$p\n" +
        "    if ($p) {{ $o.pool_user = [string]$p.ProcessModel.UserName; $o.pool_type = [string]$p.ProcessModel.IdentityType }}\n" +
        "  }}\n" +
        "  [xml]$cfg = Get-Content -LiteralPath (Join-Path $mdsPath 'web.config')\n" +
        "  $inst = @($cfg.configuration.masterDataServices.instance | Where-Object {{ $_.siteName -eq " + common::ps_q(w.site) + " -and $_.virtualPath -eq '' }})[0]\n" +
        "  if ($inst) {{\n" +
        "    $cs = @($cfg.configuration.connectionStrings.add | Where-Object {{ $_.name -eq $inst.connectionName }})[0]\n" +
        "    if ($cs) {{ $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($cs.connectionString); $o.db_server = $b.DataSource; $o.db_name = $b.InitialCatalog }}\n" +
        "  }}\n" +
        "  $td = [string]$cfg.configuration.'system.web'.compilation.tempDirectory\n" +
        "  $o.temp_ok = (-not $td) -or (Test-Path -LiteralPath $td)\n" +
        "  $o.in_group = $false\n" +
        "  if (" + common::ps_q(w.identity) + " -ne '') {{\n" +
        "    $sid = (New-Object Security.Principal.NTAccount(" + common::ps_q(w.identity) + ")).Translate([Security.Principal.SecurityIdentifier]).Value\n" +
        "    $o.in_group = [bool](@(Get-LocalGroupMember -Name MDS_ServiceAccounts -ErrorAction SilentlyContinue | Where-Object {{ $_.SID.Value -eq $sid }}).Count)\n" +
        "  }}\n" +
        "}}\n" +
        "$o | ConvertTo-Json -Compress -Depth 4"
    let out = mds::run(w.dir, "reading MDS web application " + w.site, body, #{})?
    common::ps_json_text("reading MDS web application " + w.site, out)
}

fn s_of(v: Value, k: string) -> string {
    if let Some(x) = v.get(k) { if let Some(s) = x.as_string() { return s } }
    ""
}

fn b_of(v: Value, k: string) -> bool {
    if let Some(x) = v.get(k) { return x.as_bool().unwrap_or(false) }
    false
}

fn list_of(v: Value, k: string) -> List[string] {
    let out = []
    if let Some(x) = v.get(k) {
        if let Some(l) = x.as_list() { for i in l { out.push(i.as_string().unwrap_or("")) } }
        else if let Some(s) = x.as_string() { out.push(s) }
    }
    out
}

fn norm_dir(p: string) -> string {
    let t = p.trim().to_lower()
    if t.ends_with("\\") { t.slice(0, t.len() - 1) } else { t }
}

fn exec_ok(w: Want) -> Result[bool, string] {
    let db = common::tsql_id(w.database)
    let q = "SELECT CASE WHEN DB_ID(" + common::tsql_lit(w.database) + ") IS NOT NULL AND EXISTS (SELECT 1 FROM " + db + ".sys.database_role_members rm " +
        "JOIN " + db + ".sys.database_principals r ON r.principal_id = rm.role_principal_id " +
        "JOIN " + db + ".sys.database_principals u ON u.principal_id = rm.member_principal_id " +
        "WHERE r.name = N'mds_exec' AND u.sid = SUSER_SID(" + common::tsql_lit(w.identity) + ")) THEN 1 ELSE 0 END;"
    Ok(common::run_scalar(Value::Map(#{ "server": Value::String(w.server) }), q)? == "1")
}

fn revision(site: string) -> Result[string, string] {
    if let Some(v) = registry::read(marker_key(site), "password_revision")? { return Ok(v.as_string().unwrap_or("")) }
    Ok("")
}

// What differs on an existing site, in the order apply fixes it.
fn drift(params: Value, w: Want, st: Value) -> Result[List[string], string] {
    if norm_dir(s_of(st, "physical")) != norm_dir(s_of(st, "path")) {
        return Err("IIS site " + w.site + " serves " + s_of(st, "physical") + ", not the MDS web application at " + s_of(st, "path") + "; pick another site name")
    }
    let out = []
    let want_binding = "http *:" + str(w.port) + ":"
    let have = list_of(st, "bindings")
    if have.len() != 1 || have.get(0).unwrap_or("").to_lower() != want_binding { out.push("port") }
    if !b_of(st, "pool_exists") || s_of(st, "app_pool").to_lower() != w.pool.to_lower() { out.push("app_pool") }
    else if s_of(st, "pool_user").to_lower() != w.identity.to_lower() { out.push("identity") }
    else if revision(w.site)? != common::param_str(params, "password_revision", "") { out.push("password") }
    if !b_of(st, "in_group") || !b_of(st, "temp_ok") { out.push("service_accounts_group") }
    if s_of(st, "db_server").to_lower() != w.server.to_lower() || s_of(st, "db_name").to_lower() != w.database.to_lower() { out.push("database") }
    else if !exec_ok(w)? { out.push("database_access") }
    Ok(out)
}

fn need(w: Want) -> Result[unit, string] {
    if w.identity == "" { return Err("'identity' is required: MDS refuses built-in accounts, so the application pool runs as a Windows user") }
    if w.database == "" { return Err("'database' is required (an MDS database, see mssql.mds_database)") }
    Ok(())
}

fn prereqs_ok(st: Value) -> Result[unit, string] {
    let missing = list_of(st, "missing")
    if !missing.is_empty() {
        return Err("IIS role services that Master Data Services needs are not installed: " + missing.join(", ") +
            " (windows_features.windows_server_feature installs them)")
    }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let w = want(params)?
    let st = state(w)?
    if !common::want_present(params)? {
        return Ok(if b_of(st, "exists") { CheckResult::NotConfigured } else { CheckResult::AlreadyConfigured })
    }
    need(w)?
    prereqs_ok(st)?
    if !b_of(st, "exists") { return Ok(CheckResult::NotConfigured) }
    let d = drift(params, w, st)?
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("MDS web application " + w.site + " differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

// PowerShell binding $site, $app and $pool to the IIS objects MDS expects.
fn iis_objects_ps(w: Want) -> string {
    "$sm = New-Object Microsoft.Web.Administration.ServerManager\n" +
        "$site = $sm.Sites[" + common::ps_q(w.site) + "]; $app = $site.Applications['/']; $pool = $sm.ApplicationPools[" + common::ps_q(w.pool) + "]\n"
}

fn configure_ps(w: Want) -> string {
    mds::connect_ps(w.server) +
        "[void](Invoke-CwMds $null $tWeb 'AddServiceAccountToDatabase' @($admin, $pool, " + common::ps_q(w.database) + "))\n" +
        "[void](Invoke-CwMds $null $tWeb 'ApplyMdsConfiguration' @($admin, $site, $pool, $app, " + common::ps_q(w.server) + ", " + common::ps_q(w.database) + ", " + common::ps_q(w.url) + "))\n" +
        temp_dir_ps()
}

// ApplyMdsConfiguration points web.config's compilation tempDirectory at an
// MDSTempDir it does not create (beside WebApplication, in 2019), and ASP.NET
// refuses to start without it. CreateTemporaryDirectory(root) makes
// root\MDSTempDir with the MDS_ServiceAccounts rule.
fn temp_dir_ps() -> string {
    "[xml]$wc = Get-Content -LiteralPath (Join-Path $mdsPath 'web.config')\n" +
        "$td = [string]$wc.configuration.'system.web'.compilation.tempDirectory\n" +
        "if ($td -and -not (Test-Path -LiteralPath $td)) {{\n" +
        "  if ((Split-Path $td -Leaf) -ne 'MDSTempDir') {{ throw ('web.config names the temp directory ' + $td + ', which does not exist') }}\n" +
        "  [void](Invoke-CwMds $null $tWeb 'CreateTemporaryDirectory' @((Split-Path $td -Parent)))\n" +
        "}}\n"
}

// The pool identity must be in MDS_ServiceAccounts, which MDSTempDir and
// web.config grant access to; without these the site answers 500.
fn access_ps(w: Want) -> string {
    "[void](Invoke-CwMds $null $tWeb 'AddServiceAccountToGroup' @(" + common::ps_q(w.identity) + "))\n" +
        "[void](Invoke-CwMds $null $tWeb 'CreateTemporaryDirectory' @($mdsPath))\n" +
        "[void](Invoke-CwMds $null $tWeb 'SetWebConfigPermissions' @($mdsPath))\n"
}

// A recycle starts a worker with a fresh logon, so the new group membership counts.
fn recycle_ps(w: Want) -> string {
    "$sm = New-Object Microsoft.Web.Administration.ServerManager\n" +
        "$p = $sm.ApplicationPools[" + common::ps_q(w.pool) + "]\n" +
        "if ($p.State -eq 'Started') {{ [void]$p.Recycle() }} else {{ [void]$p.Start() }}\n"
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    let st = state(w)?
    let secrets = #{ "CW_MDS_PASSWORD": Value::String(w.password) }
    let pre = "[void][Reflection.Assembly]::LoadWithPartialName('Microsoft.Web.Administration')\n"
    if !common::want_present(params)? {
        if !b_of(st, "exists") { return Ok(ApplyResult::Success) }
        log::info("removing MDS web application " + w.site)
        let body = pre +
            "[void](Invoke-CwMds $null $tWeb 'RemoveWebConfigurationSettings' @((Join-Path $mdsPath 'web.config'), " + common::ps_q(w.site) + ", ''))\n" +
            "$sm = New-Object Microsoft.Web.Administration.ServerManager\n" +
            "$s = $sm.Sites[" + common::ps_q(w.site) + "]\n" +
            "$poolName = $s.Applications['/'].ApplicationPoolName\n" +
            "$sm.Sites.Remove($s)\n" +
            "$used = @($sm.Sites | ForEach-Object {{ $_.Applications }} | Where-Object {{ $_.ApplicationPoolName -eq $poolName }}).Count\n" +
            "if ($used -eq 0 -and $sm.ApplicationPools[$poolName]) {{ $sm.ApplicationPools.Remove($sm.ApplicationPools[$poolName]) }}\n" +
            "$sm.CommitChanges()\n"
        mds::run(w.dir, "removing MDS web application " + w.site, body, #{})?
        return Ok(ApplyResult::Success)
    }
    need(w)?
    prereqs_ok(st)?
    if !b_of(st, "exists") {
        if w.password == "" { return Err("'password' is required to create the application pool for " + w.identity) }
        log::info("creating MDS web application " + w.site + " on port " + str(w.port))
        let body = pre + access_ps(w) +
            "$pw = ConvertTo-SecureString $env:CW_MDS_PASSWORD -AsPlainText -Force\n" +
            "$a = [object[]]@(" + common::ps_q(w.site) + ", " + common::ps_q(w.pool) + ", " + common::ps_q(w.identity) + ", $pw, $mdsPath, " +
            common::ps_q("*:" + str(w.port) + ":") + ", 'http', $null, $null)\n" +
            "$site = Invoke-CwMds $null $tWeb 'CreateSite' $a\n" +
            "$app = $a[7]; $pool = $a[8]\n" +
            configure_ps(w) + recycle_ps(w)
        mds::run(w.dir, "creating MDS web application " + w.site, body, secrets)?
        registry::write(marker_key(w.site), "password_revision", Value::String(common::param_str(params, "password_revision", "")), "sz")?
        return Ok(ApplyResult::Success)
    }
    let d = drift(params, w, st)?
    if d.is_empty() { return Ok(ApplyResult::Success) }
    log::info("updating MDS web application " + w.site + ": " + d.join(", "))
    let body = pre
    if d.contains("port") {
        body = body + "$sm = New-Object Microsoft.Web.Administration.ServerManager\n" +
            "$s = $sm.Sites[" + common::ps_q(w.site) + "]; $s.Bindings.Clear(); [void]$s.Bindings.Add(" + common::ps_q("*:" + str(w.port) + ":") + ", 'http'); $sm.CommitChanges()\n"
    }
    let pool_change = d.contains("app_pool") || d.contains("identity") || d.contains("password")
    // The identity joins MDS_ServiceAccounts before the pool runs as it: WAS
    // logs the identity on when the pool changes and keeps that token, so a
    // group added afterwards is missing from the worker (IIS 500.19, access
    // denied on web.config) until WAS restarts.
    if pool_change || d.contains("service_accounts_group") { body = body + access_ps(w) }
    if pool_change {
        if w.password == "" { return Err("'password' is required to set the application pool identity " + w.identity) }
        body = body + "$pw = ConvertTo-SecureString $env:CW_MDS_PASSWORD -AsPlainText -Force\n" +
            "$sm = New-Object Microsoft.Web.Administration.ServerManager\n" +
            "if ($sm.ApplicationPools[" + common::ps_q(w.pool) + "]) {{ [void](Invoke-CwMds $null $tWeb 'UpdateApplicationPool' @(" + common::ps_q(w.pool) + ", " + common::ps_q(w.identity) + ", $pw)) }}\n" +
            "else {{ [void](Invoke-CwMds $null $tWeb 'CreateApplicationPool' @(" + common::ps_q(w.pool) + ", " + common::ps_q(w.identity) + ", $pw)) }}\n" +
            "$sm = New-Object Microsoft.Web.Administration.ServerManager\n" +
            "$sm.Sites[" + common::ps_q(w.site) + "].Applications['/'].ApplicationPoolName = " + common::ps_q(w.pool) + "; $sm.CommitChanges()\n"
    }
    if d.contains("service_accounts_group") { body = body + temp_dir_ps() }
    if pool_change || d.contains("database") || d.contains("database_access") {
        body = body + iis_objects_ps(w) + configure_ps(w)
    }
    body = body + recycle_ps(w)
    mds::run(w.dir, "updating MDS web application " + w.site, body, secrets)?
    if pool_change { registry::write(marker_key(w.site), "password_revision", Value::String(common::param_str(params, "password_revision", "")), "sz")? }
    Ok(ApplyResult::Success)
}
