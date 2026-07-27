use value
use fs
use service

fn verify(facts: Value) -> Result[bool, string] {
    // The role puts appcmd and the config store on disk...
    if !fs::exists("C:\\Windows\\System32\\inetsrv\\appcmd.exe") { return Ok(false) }
    if !fs::exists("C:\\Windows\\System32\\inetsrv\\config\\applicationHost.config") { return Ok(false) }
    // ...and Web-Scripting-Tools, which the rest of the package needs, brings
    // the WebAdministration module with it.
    if !fs::exists("C:\\Windows\\System32\\inetsrv\\Microsoft.Web.Administration.dll") { return Ok(false) }
    // The World Wide Web Publishing Service is what actually serves requests.
    Ok(service::status("W3SVC")? == "running")
}
