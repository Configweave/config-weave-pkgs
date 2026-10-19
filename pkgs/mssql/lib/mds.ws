use value
use fs
use path
use common

// Master Data Services has no command line for what MDS Configuration
// Manager does, so these resources drive the classes Configuration Manager
// itself uses, in <MDS dir>\WebApplication\bin\
// Microsoft.MasterDataServices.Configuration.dll, through reflection. The
// members are internal and undocumented and change between releases, so
// only the SQL Server versions whose assembly was checked are accepted:
// 2019 (150) and older. All of the reflection is in this file:
//
//   ConfigurationAdministration (internal; parameterless constructor)
//     TestNewConnection(SqlConnectionStringBuilder) -> DatabaseServerInformation
//     CreateDatabase(DatabaseInformation) -> DatabaseInformation
//   DatabaseInformation (public; internal setters)
//     Name, Collation, MdsAdministrator, Server (DatabaseServerInformation)
//   WebUtilities (public static class; internal statics)
//     GetWebApplicationInstallationPath() -> string
//     AddServiceAccountToGroup(string identity)        MDS_ServiceAccounts
//     CreateTemporaryDirectory(string installPath)     MDSTempDir and its ACL
//     SetWebConfigPermissions(string installPath)      web.config read ACL
//     CreateSite(site, pool, user, SecureString, installPath, binding,
//                protocol, out Application, out ApplicationPool) -> Site
//     UpdateApplicationPool(pool, user, SecureString)
//     AddServiceAccountToDatabase(admin, ApplicationPool, database)  mds_exec
//     ApplyMdsConfiguration(admin, Site, ApplicationPool, Application,
//                           server, database, webAppUrl)
//     RemoveWebConfigurationSettings(configPath, site, virtualPath)
//
// Invoke() wraps a failure in TargetInvocationException, whose message is
// "Exception has been thrown by the target of an invocation"; Invoke-CwMds
// rethrows the inner exception so the MDS message is what reaches the user.

fn supported_versions() -> List[string] { ["150", "140", "130", "120", "110"] }

fn sql_root() -> string { "C:\\Program Files\\Microsoft SQL Server" }

fn mds_dir(version: string) -> string {
    path::join(path::join(sql_root(), version), "Master Data Services")
}

fn config_dll(dir: string) -> string {
    path::join(dir, "WebApplication\\bin\\Microsoft.MasterDataServices.Configuration.dll")
}

// The MDS install to use: `wanted` (a version folder such as 150) or the
// newest one installed. Anything newer than SQL Server 2019 is refused
// rather than guessed at, because the internal members may differ.
fn locate(resource: string, wanted: string) -> Result[string, string] {
    if wanted != "" {
        if !supported_versions().contains(wanted) {
            return Err("mssql." + resource + " supports SQL Server 2019 and older (mds_version 150, 140, 130, 120 or 110); got mds_version " + wanted)
        }
        let d = mds_dir(wanted)
        if !fs::exists(config_dll(d)) { return Err("Master Data Services " + wanted + " is not installed: " + config_dll(d) + " does not exist") }
        return Ok(d)
    }
    let found: List[string] = []
    if let Ok(entries) = fs::list_dir(sql_root()) {
        for e in entries {
            let name = path::filename(e)
            if name.parse_int().is_some() && fs::exists(config_dll(mds_dir(name))) { found.push(name) }
        }
    }
    if found.is_empty() { return Err("Master Data Services is not installed (no " + sql_root() + "\\<version>\\Master Data Services); install it with SQL Server setup, FEATURES=MDS") }
    let newest = found.fold("", |acc, v| if acc == "" || v.parse_int().unwrap_or(0) > acc.parse_int().unwrap_or(0) { v } else { acc })
    if !supported_versions().contains(newest) {
        return Err("mssql." + resource + " supports SQL Server 2019 and older; found " + newest + " at " + mds_dir(newest) +
            " (set mds_version to use an older MDS installed beside it)")
    }
    Ok(mds_dir(newest))
}

// PowerShell that loads the configuration assembly from `dir` and defines
// the reflection helpers, $tAdmin and $tWeb.
fn prelude(dir: string) -> string {
    "$mdsBin = " + common::ps_q(path::join(dir, "WebApplication\\bin")) + "\n" +
        "[AppDomain]::CurrentDomain.add_AssemblyResolve({{ param($s, $e) $n = (New-Object Reflection.AssemblyName($e.Name)).Name; $p = Join-Path $mdsBin ($n + '.dll'); if (Test-Path -LiteralPath $p) {{ [Reflection.Assembly]::LoadFrom($p) }} else {{ $null }} }})\n" +
        "$mdsAsm = [Reflection.Assembly]::LoadFrom((Join-Path $mdsBin 'Microsoft.MasterDataServices.Configuration.dll'))\n" +
        "$F = [Reflection.BindingFlags]'Public,NonPublic,Instance,Static'\n" +
        "$tAdmin = $mdsAsm.GetType('Microsoft.MasterDataServices.Configuration.ConfigurationAdministration', $true)\n" +
        "$tWeb = $mdsAsm.GetType('Microsoft.MasterDataServices.Configuration.WebUtilities', $true)\n" +
        "$tDb = $mdsAsm.GetType('Microsoft.MasterDataServices.Configuration.DatabaseInformation', $true)\n" +
        // Calls a member by name and argument count. PowerShell hands .NET a
        // PSObject wrapper unless it is unwrapped first. $a is returned
        // filled in, for out parameters.
        "function Invoke-CwMds($obj, $type, $name, [object[]]$a) {{\n" +
        "  $m = @($type.GetMethods($F) | Where-Object {{ $_.Name -eq $name -and $_.GetParameters().Count -eq $a.Count }})[0]\n" +
        "  if (-not $m) {{ throw ($type.FullName + '.' + $name + ' with ' + $a.Count + ' arguments does not exist in this MDS version') }}\n" +
        "  for ($i = 0; $i -lt $a.Count; $i++) {{ if ($null -ne $a[$i] -and $a[$i] -is [Management.Automation.PSObject]) {{ $a[$i] = $a[$i].PSObject.BaseObject }} }}\n" +
        "  try {{ return ,$m.Invoke($obj, $a) }} catch [Reflection.TargetInvocationException] {{ $x = $_.Exception; while ($x -is [Reflection.TargetInvocationException] -and $x.InnerException) {{ $x = $x.InnerException }}; throw ($name + ': ' + $x.Message) }}\n" +
        "}}\n" +
        "function Set-CwProp($o, $n, $v) {{ $o.GetType().GetProperty($n, $F).SetValue($o, $v, $null) }}\n" +
        "$mdsPath = Invoke-CwMds $null $tWeb 'GetWebApplicationInstallationPath' @()\n"
}

// PowerShell binding $admin to a ConfigurationAdministration connected to
// `server` with integrated security, and $srvInfo to its server information.
fn connect_ps(server: string) -> string {
    "$admin = [Activator]::CreateInstance($tAdmin, $true)\n" +
        "$csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder\n" +
        "$csb['Data Source'] = " + common::ps_q(server) + "; $csb['Integrated Security'] = $true\n" +
        "$srvInfo = Invoke-CwMds $admin $tAdmin 'TestNewConnection' @($csb)\n" +
        "if (-not $srvInfo.IsValid) {{ throw ('SQL Server ' + " + common::ps_q(server) + " + ' cannot host an MDS database (version ' + $srvInfo.SqlVersion + ', edition valid: ' + $srvInfo.IsSkuValid + ')') }}\n"
}

// Runs `body` after the prelude; `env` carries secrets. Returns stdout.
fn run(dir: string, what: string, body: string, env: Map[string, Value]) -> Result[string, string] {
    common::ps_env(what, prelude(dir) + body, env, 1800)
}
