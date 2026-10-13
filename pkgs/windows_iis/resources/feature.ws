use value
use shell
use log
use common

// ---------------------------------------------------------------------------
// IIS role services.
//
// This is the one resource here that does not touch WebAdministration: it is
// what installs the module the rest of the package needs, so the shared
// ps_out/ps_run above — which import WebAdministration — cannot be used. The
// ServerManager cmdlets below stand in for them.
//
// The symbol names are the Web-* feature names made WCL-spellable: a WCL
// symbol stops at [A-Za-z0-9_], so Web-Asp-Net45 is :asp_net45 and the table
// puts the hyphens back. config-weave has already checked the value against
// the declared set, so all that is left here is spelling.
// ---------------------------------------------------------------------------

fn feature_names() -> List[List[string]] { [
        ["web_server", "Web-Server"],
        ["web_webserver", "Web-WebServer"],
        ["common_http", "Web-Common-Http"],
        ["default_doc", "Web-Default-Doc"],
        ["dir_browsing", "Web-Dir-Browsing"],
        ["http_errors", "Web-Http-Errors"],
        ["static_content", "Web-Static-Content"],
        ["http_redirect", "Web-Http-Redirect"],
        ["dav_publishing", "Web-DAV-Publishing"],
        ["health", "Web-Health"],
        ["http_logging", "Web-Http-Logging"],
        ["custom_logging", "Web-Custom-Logging"],
        ["log_libraries", "Web-Log-Libraries"],
        ["odbc_logging", "Web-ODBC-Logging"],
        ["request_monitor", "Web-Request-Monitor"],
        ["http_tracing", "Web-Http-Tracing"],
        ["performance", "Web-Performance"],
        ["stat_compression", "Web-Stat-Compression"],
        ["dyn_compression", "Web-Dyn-Compression"],
        ["security", "Web-Security"],
        ["filtering", "Web-Filtering"],
        ["basic_auth", "Web-Basic-Auth"],
        ["cert_provider", "Web-CertProvider"],
        ["client_auth", "Web-Client-Auth"],
        ["digest_auth", "Web-Digest-Auth"],
        ["cert_auth", "Web-Cert-Auth"],
        ["ip_security", "Web-IP-Security"],
        ["url_auth", "Web-Url-Auth"],
        ["windows_auth", "Web-Windows-Auth"],
        ["app_dev", "Web-App-Dev"],
        ["net_ext", "Web-Net-Ext"],
        ["net_ext45", "Web-Net-Ext45"],
        ["app_init", "Web-AppInit"],
        ["asp", "Web-ASP"],
        ["asp_net", "Web-Asp-Net"],
        ["asp_net45", "Web-Asp-Net45"],
        ["cgi", "Web-CGI"],
        ["isapi_ext", "Web-ISAPI-Ext"],
        ["isapi_filter", "Web-ISAPI-Filter"],
        ["includes", "Web-Includes"],
        ["websockets", "Web-WebSockets"],
        ["ftp_server", "Web-Ftp-Server"],
        ["ftp_service", "Web-Ftp-Service"],
        ["ftp_ext", "Web-Ftp-Ext"],
        ["mgmt_tools", "Web-Mgmt-Tools"],
        ["mgmt_console", "Web-Mgmt-Console"],
        ["scripting_tools", "Web-Scripting-Tools"],
        ["mgmt_service", "Web-Mgmt-Service"],
        ["mgmt_compat", "Web-Mgmt-Compat"],
        ["metabase", "Web-Metabase"],
        ["lgcy_mgmt_console", "Web-Lgcy-Mgmt-Console"],
        ["lgcy_scripting", "Web-Lgcy-Scripting"],
        ["wmi", "Web-WMI"],
    ] }

fn feature_name(params: Value) -> Result[string, string] {
    let sym = common::param_str(params, "name", "")
    if sym == "" { return Err("missing 'name' parameter") }
    for row in feature_names() {
        if row.get(0).unwrap_or("") == sym { return Ok(row.get(1).unwrap_or("")) }
    }
    Err("unknown role service ':" + sym + "'")
}

// Get-WindowsFeature is Server-only; it errors on a client SKU, and this
// package targets Windows Server.
fn installed(name: string) -> Result[bool, string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; if ((Get-WindowsFeature -Name " + common::ps_q(name) +
        ").Installed) {{ 'YES' }} else {{ 'NO' }}", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "YES")
}

fn check(params: Value) -> Result[CheckResult, string] {
    if installed(feature_name(params)?)? == common::want_present(params)? {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = feature_name(params)?
    let cmdlet = if common::want_present(params)? {
        let mgmt = if common::param_bool(params, "include_management_tools", false) {
            " -IncludeManagementTools"
        } else { "" }
        "Install-WindowsFeature -Name " + common::ps_q(name) + mgmt
    } else {
        "Uninstall-WindowsFeature -Name " + common::ps_q(name)
    }
    log::info("role service " + name)
    // 3010 is the MSI convention for "done, but reboot"; using it as the exit
    // code keeps the reboot signal out of stdout parsing.
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; $r = " + cmdlet +
        "; if ($r.RestartNeeded -ne 'No') {{ exit 3010 }} else {{ exit 0 }}", Value::Null)?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
