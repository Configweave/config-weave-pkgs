use value
use registry

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

// Windows Update for Business settings — the "Select when Preview Builds and
// Feature Updates are received" family of Group Policy settings.
fn wu_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate" }

fn reg_int(name: string, fallback: int) -> Result[int, string] {
    if let Some(v) = registry::read(wu_key(), name)? {
        return Ok(v.as_int().unwrap_or(fallback))
    }
    Ok(fallback)
}

fn want_branch(params: Value) -> Result[int, string] {
    let b = param_str(params, "branch_readiness", "unmanaged")
    if b == "targeted" { return Ok(16) }
    if b == "broad" { return Ok(32) }
    if b == "unmanaged" { return Ok(-1) }
    Err("invalid 'branch_readiness' value '" + b + "' (expected :targeted, :broad or :unmanaged)")
}

fn days(params: Value, key: string, limit: int) -> Result[int, string] {
    let d = param_int(params, key, -1)
    if d == -1 { return Ok(-1) }
    if d < 0 || d > limit { return Err("'" + key + "' must be 0-" + str(limit) + " (or -1 to leave it unmanaged)") }
    Ok(d)
}

fn hour(params: Value, key: string) -> Result[int, string] {
    let h = param_int(params, key, -1)
    if h == -1 { return Ok(-1) }
    if h < 0 || h > 23 { return Err("'" + key + "' must be 0-23 (or -1 to leave it unmanaged)") }
    Ok(h)
}

fn active_hours(params: Value) -> Result[bool, string] {
    let s = hour(params, "active_hours_start")?
    let e = hour(params, "active_hours_end")?
    if s == -1 && e == -1 { return Ok(false) }
    if s == -1 || e == -1 { return Err("active_hours_start and active_hours_end must be set together") }
    Ok(true)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let feature = days(params, "feature_update_days", 365)?
    if feature != -1 {
        if reg_int("DeferFeatureUpdatesPeriodInDays", 0)? != feature { return Ok(CheckResult::NotConfigured) }
        if reg_int("DeferFeatureUpdates", 0)? != 1 { return Ok(CheckResult::NotConfigured) }
    }
    let quality = days(params, "quality_update_days", 30)?
    if quality != -1 {
        if reg_int("DeferQualityUpdatesPeriodInDays", 0)? != quality { return Ok(CheckResult::NotConfigured) }
        if reg_int("DeferQualityUpdates", 0)? != 1 { return Ok(CheckResult::NotConfigured) }
    }
    let branch = want_branch(params)?
    if branch != -1 && reg_int("BranchReadinessLevel", 0)? != branch { return Ok(CheckResult::NotConfigured) }
    if active_hours(params)? {
        if reg_int("SetActiveHours", 0)? != 1 { return Ok(CheckResult::NotConfigured) }
        if reg_int("ActiveHoursStart", -1)? != hour(params, "active_hours_start")? { return Ok(CheckResult::NotConfigured) }
        if reg_int("ActiveHoursEnd", -1)? != hour(params, "active_hours_end")? { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    registry::create_key(wu_key())?
    let feature = days(params, "feature_update_days", 365)?
    if feature != -1 {
        // The period is ignored unless its companion flag is set.
        registry::write(wu_key(), "DeferFeatureUpdates", Value::Int(1), "dword")?
        registry::write(wu_key(), "DeferFeatureUpdatesPeriodInDays", Value::Int(feature), "dword")?
    }
    let quality = days(params, "quality_update_days", 30)?
    if quality != -1 {
        registry::write(wu_key(), "DeferQualityUpdates", Value::Int(1), "dword")?
        registry::write(wu_key(), "DeferQualityUpdatesPeriodInDays", Value::Int(quality), "dword")?
    }
    let branch = want_branch(params)?
    if branch != -1 {
        registry::write(wu_key(), "BranchReadinessLevel", Value::Int(branch), "dword")?
    }
    if active_hours(params)? {
        registry::write(wu_key(), "SetActiveHours", Value::Int(1), "dword")?
        registry::write(wu_key(), "ActiveHoursStart", Value::Int(hour(params, "active_hours_start")?), "dword")?
        registry::write(wu_key(), "ActiveHoursEnd", Value::Int(hour(params, "active_hours_end")?), "dword")?
    }
    Ok(ApplyResult::Success)
}
