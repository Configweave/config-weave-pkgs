use value
use registry

fn au_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" }
fn wu_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate" }

fn gone(key: string, names: List[string]) -> Result[bool, string] {
    for n in names {
        if let Some(_) = registry::read(key, n)? { return Err(n + " is still set; ensure = :absent should have deleted it") }
    }
    Ok(true)
}

fn verify(facts: Value) -> Result[bool, string] {
    gone(au_key(), ["NoAutoUpdate", "AUOptions", "ScheduledInstallDay", "ScheduledInstallTime",
        "NoAutoRebootWithLoggedOnUsers", "DetectionFrequency", "DetectionFrequencyEnabled", "UseWUServer"])?
    gone(wu_key(), ["WUServer", "WUStatusServer", "TargetGroup", "TargetGroupEnabled",
        "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates",
        "DeferQualityUpdatesPeriodInDays", "BranchReadinessLevel", "SetActiveHours",
        "ActiveHoursStart", "ActiveHoursEnd"])?
    Ok(true)
}
