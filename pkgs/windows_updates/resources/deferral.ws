use value
use common

// Windows Update for Business settings — the "Select when Preview Builds and
// Feature Updates are received" family of Group Policy settings, all on the
// WindowsUpdate key.
fn names() -> List[string] {
    ["DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays",
     "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays",
     "BranchReadinessLevel", "SetActiveHours", "ActiveHoursStart", "ActiveHoursEnd"]
}

// 32 (the old Semi-Annual Channel, "broad") is ignored from Windows 10 1903
// on, where both channels merged into 16.
fn want_branch(params: Value) -> Result[int, string] {
    let b = common::param_str(params, "branch_readiness", "unmanaged")
    if b == "general_availability" { return Ok(16) }
    if b == "release_preview" { return Ok(8) }
    if b == "beta" { return Ok(4) }
    if b == "dev" { return Ok(2) }
    if b == "unmanaged" { return Ok(-1) }
    Err("invalid 'branch_readiness' value '" + b + "' (expected :general_availability, :release_preview, :beta, :dev or :unmanaged)")
}

fn days(params: Value, key: string, limit: int) -> Result[int, string] {
    let d = common::param_int(params, key, -1)
    if d == -1 { return Ok(-1) }
    if d < 0 || d > limit { return Err("'" + key + "' must be 0-" + str(limit) + " (or -1 to leave it unmanaged)") }
    Ok(d)
}

fn hour(params: Value, key: string) -> Result[int, string] {
    let h = common::param_int(params, key, -1)
    if h == -1 { return Ok(-1) }
    if h < 0 || h > 23 { return Err("'" + key + "' must be 0-23 (or -1 to leave it unmanaged)") }
    Ok(h)
}

// Windows rejects an active-hours span longer than 18 hours (the default
// ActiveHoursMaxRange), wrapping past midnight when end < start.
fn active_hours(params: Value) -> Result[bool, string] {
    let s = hour(params, "active_hours_start")?
    let e = hour(params, "active_hours_end")?
    if s == -1 && e == -1 { return Ok(false) }
    if s == -1 || e == -1 { return Err("active_hours_start and active_hours_end must be set together") }
    if s == e { return Err("active_hours_start and active_hours_end must differ") }
    let span = (e - s + 24) % 24
    if span > 18 { return Err("active hours span " + str(span) + " hours; Windows allows at most 18") }
    Ok(true)
}

// The wanted values in names() order; -1 leaves a value unmanaged. Each
// period is ignored unless its companion flag is set.
fn wanted(params: Value) -> Result[List[int], string] {
    let feature = days(params, "feature_update_days", 365)?
    let quality = days(params, "quality_update_days", 30)?
    let hours = active_hours(params)?
    Ok([if feature == -1 { -1 } else { 1 }, feature,
        if quality == -1 { -1 } else { 1 }, quality,
        want_branch(params)?,
        if hours { 1 } else { -1 },
        hour(params, "active_hours_start")?, hour(params, "active_hours_end")?])
}

fn absent(params: Value) -> Result[bool, string] {
    if common::want_present(params)? { return Ok(false) }
    for w in wanted(params)? {
        if w != -1 { return Err("ensure = :absent removes every deferral and active-hours value; leave the other params unmanaged") }
    }
    Ok(true)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if absent(params)? {
        if common::any_value(common::wu_key(), names())? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = wanted(params)?
    let n = names()
    for i in 0..n.len() {
        if !common::int_matches(common::wu_key(), n[i], want[i])? { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if absent(params)? {
        common::delete_values(common::wu_key(), names())?
        return Ok(ApplyResult::Success)
    }
    let want = wanted(params)?
    let n = names()
    for i in 0..n.len() { common::put_int(common::wu_key(), n[i], want[i])? }
    Ok(ApplyResult::Success)
}
