use value
use registry

fn au_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" }
fn wu_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate" }

fn expect(key: string, name: string, want: int) -> Result[bool, string] {
    if let Some(v) = registry::read(key, name)? {
        if v.as_int().unwrap_or(-1) == want { return Ok(true) }
        return Err(name + " is " + str(v.as_int().unwrap_or(-1)) + ", expected " + str(want))
    }
    Err(name + " is absent; the resource should have written it")
}

fn verify(facts: Value) -> Result[bool, string] {
    // Read the policy back out of the registry rather than trusting check.
    if !expect(au_key(), "NoAutoUpdate", 0)? { return Ok(false) }
    if !expect(au_key(), "AUOptions", 4)? { return Ok(false) }
    if !expect(au_key(), "ScheduledInstallDay", 4)? { return Ok(false) }
    if !expect(au_key(), "ScheduledInstallTime", 3)? { return Ok(false) }
    if !expect(au_key(), "NoAutoRebootWithLoggedOnUsers", 1)? { return Ok(false) }

    if !expect(wu_key(), "DeferQualityUpdates", 1)? { return Ok(false) }
    if !expect(wu_key(), "DeferQualityUpdatesPeriodInDays", 7)? { return Ok(false) }
    if !expect(wu_key(), "BranchReadinessLevel", 32)? { return Ok(false) }
    if !expect(wu_key(), "SetActiveHours", 1)? { return Ok(false) }
    if !expect(wu_key(), "ActiveHoursStart", 8)? { return Ok(false) }
    if !expect(wu_key(), "ActiveHoursEnd", 18)? { return Ok(false) }
    Ok(true)
}
