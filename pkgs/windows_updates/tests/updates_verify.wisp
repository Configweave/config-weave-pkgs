use value
use registry
use service

fn verify(facts: Value) -> Result[bool, string] {
    let au = registry::read("HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU", "NoAutoUpdate")?
    if let Some(v) = au {
        if v.as_int().unwrap_or(0) != 1 { return Ok(false) }
    } else {
        return Ok(false)
    }
    Ok(service::startup("wuauserv")? == "disabled" && service::status("wuauserv")? == "stopped")
}
