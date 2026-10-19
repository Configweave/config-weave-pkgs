use value
use registry
use env
use common

// Reporting Services plumbing: the report server's WMI provider and the
// registry entries the SSRS 2017+ / Power BI Report Server installers leave.
//
// The provider lives in root\Microsoft\SqlServer\ReportServer\RS_<instance>\
// v<NN>\Admin (v13 2016, v14 2017, v15 2019 and PBIRS, v16 2022), class
// MSReportServer_ConfigurationSetting. The version is found at run time from
// __Namespace, so one resource covers every release. Its methods return an
// object whose HRESULT is 0 on success, with the reasons in ExtendedErrors.

// The two products the standalone installer covers: [service, Instance Names\RS name].
fn product_info(product: string) -> Result[List[string], string] {
    if product == "ssrs" { return Ok(["SQLServerReportingServices", "SSRS"]) }
    if product == "pbirs" { return Ok(["PowerBIReportServer", "PBIRS"]) }
    Err("invalid 'product' value '" + product + "' (expected :ssrs or :pbirs)")
}

fn service_exists(svc: string) -> Result[bool, string] {
    registry::key_exists("HKLM\\SYSTEM\\CurrentControlSet\\Services\\" + svc)
}

// A value under HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\<id>\<sub>,
// where <id> is what Instance Names\RS maps `rs_name` to ("" when absent).
fn reg_value(rs_name: string, sub: string, value: string) -> Result[string, string] {
    let id = common::win_component_id("RS", rs_name)?
    if id == "" { return Ok("") }
    let key = "HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\" + id + "\\" + sub
    if let Some(v) = registry::read(key, value)? { return Ok(v.as_string().unwrap_or("")) }
    Ok("")
}

// The installed edition, as MSReportServer_Instance.EditionName.
fn edition(inst: string) -> Result[string, string] {
    let script = "$base = 'root\\Microsoft\\SqlServer\\ReportServer\\RS_' + " + common::ps_q(inst) + "\n" +
        "$v = @(Get-CimInstance -Namespace $base -ClassName __Namespace -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -match '^v\\d+$' }} | Sort-Object {{ [int]$_.Name.Substring(1) }} -Descending)\n" +
        "if ($v.Count -gt 0) {{ @(Get-CimInstance -Namespace ($base + '\\' + $v[0].Name) -ClassName MSReportServer_Instance)[0].EditionName }}"
    common::ps("reading the Reporting Services edition", script)
}

// PowerShell that binds $cfg to the instance's configuration object and $ns
// to its namespace. Defines Assert-CwWmi, which turns a failed method result
// into an exception carrying the provider's own messages.
fn connect_ps(inst: string) -> string {
    "$base = 'root\\Microsoft\\SqlServer\\ReportServer\\RS_' + " + common::ps_q(inst) + "\n" +
        "$vers = @(Get-CimInstance -Namespace $base -ClassName __Namespace -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -match '^v\\d+$' }} | Sort-Object {{ [int]$_.Name.Substring(1) }} -Descending)\n" +
        "if ($vers.Count -eq 0) {{ throw ('Reporting Services instance ' + " + common::ps_q(inst) + " + ' is not installed: there is no WMI namespace ' + $base) }}\n" +
        "$ns = $base + '\\' + $vers[0].Name + '\\Admin'\n" +
        "function Get-CwConfig {{ @(Get-WmiObject -Namespace $ns -Class MSReportServer_ConfigurationSetting | Where-Object {{ $_.InstanceName -eq " + common::ps_q(inst) + " }})[0] }}\n" +
        "$cfg = Get-CwConfig\n" +
        "if (-not $cfg) {{ throw ('no MSReportServer_ConfigurationSetting for instance ' + " + common::ps_q(inst) + " + ' in ' + $ns) }}\n" +
        "function Assert-CwWmi($r, $what) {{ if ($r.HRESULT -ne 0) {{ throw ($what + ' failed (HRESULT ' + $r.HRESULT + '): ' + (@($r.ExtendedErrors) + @($r.Error) -join '; ')) }} }}\n" +
        "$webApp = if ([int]$vers[0].Name.Substring(1) -ge 13) {{ 'ReportServerWebApp' }} else {{ 'ReportManager' }}\n"
}

// The configuration as a map: the properties the resources compare, plus
// `urls` (a list of {app, url}) and `web_app` (the portal's application
// name: ReportServerWebApp, or ReportManager before 2016).
fn state(inst: string) -> Result[Value, string] {
    let script = connect_ps(inst) +
        "$r = $cfg.ListReservedUrls()\n" +
        "$urls = @()\n" +
        "if ($r.HRESULT -eq 0 -and $r.Application) {{ for ($i = 0; $i -lt @($r.Application).Count; $i++) {{ $urls += [pscustomobject]@{{ app = @($r.Application)[$i]; url = @($r.UrlString)[$i] }} }} }}\n" +
        "[pscustomobject]@{{\n" +
        "  namespace = $ns; web_app = $webApp; service = [string]$cfg.ServiceName\n" +
        "  identity_actual = [string]$cfg.WindowsServiceIdentityActual; identity_configured = [string]$cfg.WindowsServiceIdentityConfigured\n" +
        "  db_server = [string]$cfg.DatabaseServerName; db_name = [string]$cfg.DatabaseName\n" +
        "  db_logon_type = [int]$cfg.DatabaseLogonType; db_logon_account = [string]$cfg.DatabaseLogonAccount\n" +
        "  vdir_ws = [string]$cfg.VirtualDirectoryReportServer; vdir_portal = [string]$cfg.VirtualDirectoryReportManager\n" +
        "  initialized = [bool]$cfg.IsInitialized; ws_enabled = [bool]$cfg.IsWebServiceEnabled\n" +
        "  portal_enabled = [bool]$cfg.IsReportManagerEnabled; svc_enabled = [bool]$cfg.IsWindowsServiceEnabled\n" +
        "  urls = @($urls)\n" +
        "  user_domain = $env:USERDOMAIN; computer = $env:COMPUTERNAME\n" +
        "}} | ConvertTo-Json -Compress -Depth 4"
    common::ps_json("reading the Reporting Services configuration of " + inst, script, #{})
}

fn str_of(v: Value, key: string) -> string {
    if let Some(x) = v.get(key) {
        if let Some(s) = x.as_string() { return s }
        if let Some(i) = x.as_int() { return str(i) }
        if let Some(b) = x.as_bool() { return if b { "true" } else { "false" } }
    }
    ""
}

fn bool_of(v: Value, key: string) -> bool {
    if let Some(x) = v.get(key) { return x.as_bool().unwrap_or(false) }
    false
}

// The URLs reserved for `app`, as the provider reports them.
fn urls_for(st: Value, app: string) -> List[string] {
    let out = []
    if let Some(l) = st.get("urls") {
        if let Some(items) = l.as_list() {
            for it in items {
                if str_of(it, "app") == app { out.push(str_of(it, "url")) }
            }
        }
    }
    out
}

// Whether `server` (host[\instance][,port]) names this machine.
fn is_local_server(server: string) -> bool {
    let host = server.split("\\").get(0).unwrap_or("").split(",").get(0).unwrap_or("").trim().to_lower()
    host == "" || host == "localhost" || host == "." || host == "(local)" || host == "127.0.0.1" || host == env::hostname().to_lower()
}

// Runs `body` against the instance's configuration object; `env` carries the
// secrets the body reads as $env:NAME. Returns stdout.
fn run(inst: string, what: string, body: string, env: Map[string, Value]) -> Result[string, string] {
    common::ps_env(what, connect_ps(inst) + body, env, 600)
}

fn call(inst: string, what: string, body: string, env: Map[string, Value]) -> Result[unit, string] {
    run(inst, what, body, env)?
    Ok(())
}
