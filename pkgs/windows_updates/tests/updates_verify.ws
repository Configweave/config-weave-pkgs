use value
use registry

fn verify(facts: Value) -> Result[bool, string] {
    // The step cleared the policy, so the value must read back as 0.
    let au = registry::read("HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU", "NoAutoUpdate")?
    if let Some(v) = au {
        return Ok(v.as_int().unwrap_or(-1) == 0)
    }
    Err("the AU policy value is absent; the resource should have written it")
}
