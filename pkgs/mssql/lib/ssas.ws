use value
use registry
use fs
use path
use service
use log
use common
use xmlfile

// Analysis Services plumbing shared by mssql.instance (features = AS) and
// mssql.analysis_services_setting. Setup registers an AS instance under
// Instance Names\OLAP (MSAS15.<instance>), keeps its settings in
// <SQLPath>\Config\msmdsrv.ini (an XML document whose root element is
// ConfigurationSettings), and runs it as MSOLAP$<instance>, or
// MSSQLServerOLAPService for the default instance.

fn service_name(inst: string) -> string {
    if inst == "" || inst == "MSSQLSERVER" { "MSSQLServerOLAPService" } else { "MSOLAP$" + inst }
}

// The server name AMO and the OLE DB provider connect to.
fn server_name(inst: string) -> string {
    if inst == "" || inst == "MSSQLSERVER" { "localhost" } else { "localhost\\" + inst }
}

fn installed(inst: string) -> Result[bool, string] {
    Ok(common::win_component_id("OLAP", inst)? != "")
}

// Path of the instance's msmdsrv.ini.
fn ini_path(inst: string) -> Result[string, string] {
    let id = common::win_component_id("OLAP", inst)?
    if id == "" { return Err("Analysis Services instance '" + inst + "' is not installed (no Instance Names\\OLAP entry)") }
    let key = "HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\" + id + "\\Setup"
    let sql_path = if let Some(v) = registry::read(key, "SQLPath")? { v.as_string().unwrap_or("") } else { "" }
    if sql_path == "" { return Err("no SQLPath under " + key) }
    let ini = path::join(path::join(sql_path, "Config"), "msmdsrv.ini")
    if !fs::exists(ini) { return Err("Analysis Services configuration file " + ini + " does not exist") }
    Ok(ini)
}

// `ThreadPool\Process\MaxThreads` (the path SSMS Server Properties shows)
// as an element path under the msmdsrv.ini root.
fn setting_xpath(setting: string) -> Result[string, string] {
    let s = setting.trim().replace("/", "\\")
    if s == "" { return Err("'setting' must not be empty") }
    let xp = "/ConfigurationSettings/" + s.split("\\").join("/")
    xmlfile::check_xpath(xp)?
    Ok(xp)
}

// Restarts the instance's service, waiting up to five minutes per phase:
// a busy server can take minutes to stop.
fn restart(inst: string) -> Result[unit, string] {
    let svc = service_name(inst)
    log::info("restarting " + svc)
    service::restart(svc, Value::Map(#{ "timeout": Value::Int(300) }))
}

// --- server administrators -------------------------------------------------------

// PowerShell that loads AMO (Microsoft.AnalysisServices) and connects $srv to
// the instance. AMO comes with the AS server and the client tools; it is
// looked for in the GAC and then under the SQL Server install root.
fn amo_connect_ps(inst: string) -> string {
    "$asm = $null\n" +
        "foreach ($n in @('Microsoft.AnalysisServices.Core', 'Microsoft.AnalysisServices')) {{ try {{ $asm = [Reflection.Assembly]::LoadWithPartialName($n) }} catch {{ }} }}\n" +
        "if (-not ('Microsoft.AnalysisServices.Server' -as [type])) {{\n" +
        "  $dll = Get-ChildItem -Path ($env:windir + '\\Microsoft.NET\\assembly\\GAC_MSIL\\Microsoft.AnalysisServices*'), ($env:ProgramFiles + '\\Microsoft SQL Server'), (${{env:ProgramFiles(x86)}} + '\\Microsoft SQL Server') -Recurse -Filter 'Microsoft.AnalysisServices.dll' -ErrorAction SilentlyContinue | Sort-Object {{ $_.VersionInfo.FileVersionRaw }} -Descending\n" +
        "  foreach ($d in $dll) {{ try {{ $core = Join-Path $d.DirectoryName 'Microsoft.AnalysisServices.Core.dll'; if (Test-Path $core) {{ [void][Reflection.Assembly]::LoadFrom($core) }}; [void][Reflection.Assembly]::LoadFrom($d.FullName); break }} catch {{ }} }}\n" +
        "}}\n" +
        "if (-not ('Microsoft.AnalysisServices.Server' -as [type])) {{ throw 'AMO (Microsoft.AnalysisServices.dll) is not installed, so the Analysis Services administrators cannot be read' }}\n" +
        "$srv = New-Object Microsoft.AnalysisServices.Server\n" +
        "$srv.Connect(" + common::ps_q(server_name(inst)) + ")\n"
}

// The members of the server Administrators role.
fn admins(inst: string) -> Result[List[string], string] {
    let script = amo_connect_ps(inst) +
        "try {{ @($srv.Roles['Administrators'].Members | ForEach-Object {{ $_.Name }}) | ForEach-Object {{ $_ }} }} finally {{ $srv.Disconnect() }}"
    let out = common::ps("reading the Analysis Services administrators of " + inst, script)?
    let res: List[string] = []
    for line in out.split("\n") {
        let t = line.trim()
        if t != "" { res.push(t) }
    }
    Ok(res)
}

fn missing_admins(inst: string, want: List[string]) -> Result[List[string], string] {
    let have = admins(inst)?.map(|a| a.to_lower())
    let out = []
    for a in want {
        if !have.contains(a.to_lower()) { out.push(a) }
    }
    Ok(out)
}

fn add_admins(inst: string, accounts: List[string]) -> Result[unit, string] {
    if accounts.is_empty() { return Ok(()) }
    let list = "@(" + accounts.map(|a| common::ps_q(a)).join(", ") + ")"
    let script = amo_connect_ps(inst) +
        "try {{\n" +
        "  $role = $srv.Roles['Administrators']\n" +
        "  foreach ($a in " + list + ") {{ [void]$role.Members.Add((New-Object Microsoft.AnalysisServices.RoleMember($a))) }}\n" +
        "  $role.Update()\n" +
        "}} finally {{ $srv.Disconnect() }}"
    log::info("adding Analysis Services administrators: " + accounts.join(", "))
    common::ps("adding Analysis Services administrators to " + inst, script)?
    Ok(())
}
