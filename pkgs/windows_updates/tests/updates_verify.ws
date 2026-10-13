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

fn expect_str(key: string, name: string, want: string) -> Result[bool, string] {
    if let Some(v) = registry::read(key, name)? {
        let have = v.as_string().unwrap_or("")
        if have == want { return Ok(true) }
        return Err(name + " is '" + have + "', expected '" + want + "'")
    }
    Err(name + " is absent; the resource should have written it")
}

fn verify(facts: Value) -> Result[bool, string] {
    // Read the policy back out of the registry rather than trusting check.
    // ScheduledInstallTime 0 and UseWUServer 0 were deleted by the setup, so
    // they prove a wanted zero is written.
    expect(au_key(), "NoAutoUpdate", 0)?
    expect(au_key(), "AUOptions", 4)?
    expect(au_key(), "ScheduledInstallDay", 4)?
    expect(au_key(), "ScheduledInstallTime", 0)?
    expect(au_key(), "NoAutoRebootWithLoggedOnUsers", 1)?
    expect(au_key(), "DetectionFrequency", 22)?
    expect(au_key(), "DetectionFrequencyEnabled", 1)?
    expect(au_key(), "UseWUServer", 0)?

    expect(wu_key(), "DeferFeatureUpdates", 1)?
    expect(wu_key(), "DeferFeatureUpdatesPeriodInDays", 30)?
    expect(wu_key(), "DeferQualityUpdates", 1)?
    expect(wu_key(), "DeferQualityUpdatesPeriodInDays", 7)?
    expect(wu_key(), "BranchReadinessLevel", 16)?
    expect(wu_key(), "SetActiveHours", 1)?
    expect(wu_key(), "ActiveHoursStart", 20)?
    expect(wu_key(), "ActiveHoursEnd", 6)?

    expect_str(wu_key(), "WUServer", "http://wsus.example.test:8530")?
    expect_str(wu_key(), "WUStatusServer", "http://wsus.example.test:8530")?
    expect_str(wu_key(), "TargetGroup", "cw-lab")?
    expect(wu_key(), "TargetGroupEnabled", 1)?
    Ok(true)
}
