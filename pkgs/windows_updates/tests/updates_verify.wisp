use value
use registry

fn verify(facts: Value) -> Result[bool, string] {
    let au = registry::read("HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU", "NoAutoUpdate")?
    if let Some(v) = au {
        return Ok(v.as_int().unwrap_or(0) == 1)
    }
    Ok(false)
}
