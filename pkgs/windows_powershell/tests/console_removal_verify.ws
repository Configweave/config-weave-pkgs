use value
use registry

fn verify(facts: Value) -> Result[bool, string] {
    let key = registry::HKLM + "\\SOFTWARE\\Policies\\Microsoft\\PowerShellCore\\ConsoleSessionConfiguration"
    if registry::read(key, "EnableConsoleSessionConfiguration")?.unwrap_or(Value::Null).as_int().unwrap_or(-1) != 0 {
        return Err("console policy was not disabled")
    }
    if registry::read(key, "ConsoleSessionConfigurationName")?.unwrap_or(Value::Null).as_string().unwrap_or("") != "CwSentinel" {
        return Err("removal changed the stored console name")
    }
    Ok(true)
}
