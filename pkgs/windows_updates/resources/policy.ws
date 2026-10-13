use value
use common

// The Automatic Updates policy key, the same one the "Configure Automatic
// Updates" Group Policy setting writes.
fn names() -> List[string] {
    ["NoAutoUpdate", "AUOptions", "ScheduledInstallDay", "ScheduledInstallTime",
     "NoAutoRebootWithLoggedOnUsers", "DetectionFrequency", "DetectionFrequencyEnabled"]
}

// Every enumerated param carries an :unmanaged member, so a playbook sets
// only the aspects it cares about and leaves the rest of the policy alone.
fn want_enabled(params: Value) -> Result[int, string] {
    let e = common::param_str(params, "enabled", "unmanaged")
    // NoAutoUpdate is inverted: 1 disables automatic updates.
    if e == "enabled" { return Ok(0) }
    if e == "disabled" { return Ok(1) }
    if e == "unmanaged" { return Ok(-1) }
    Err("invalid 'enabled' value '" + e + "' (expected :enabled, :disabled or :unmanaged)")
}

fn want_au_option(params: Value) -> Result[int, string] {
    let o = common::param_str(params, "au_option", "unmanaged")
    if o == "notify_download" { return Ok(2) }
    if o == "auto_download_notify_install" { return Ok(3) }
    if o == "auto_download_schedule_install" { return Ok(4) }
    if o == "allow_local_admin" { return Ok(5) }
    if o == "auto_download_notify_install_notify_restart" { return Ok(7) }
    if o == "unmanaged" { return Ok(-1) }
    Err("invalid 'au_option' value '" + o + "' (expected :notify_download, :auto_download_notify_install, :auto_download_schedule_install, :allow_local_admin, :auto_download_notify_install_notify_restart or :unmanaged)")
}

fn want_scheduled_day(params: Value) -> Result[int, string] {
    let d = common::param_str(params, "scheduled_day", "unmanaged")
    if d == "every_day" { return Ok(0) }
    if d == "sunday" { return Ok(1) }
    if d == "monday" { return Ok(2) }
    if d == "tuesday" { return Ok(3) }
    if d == "wednesday" { return Ok(4) }
    if d == "thursday" { return Ok(5) }
    if d == "friday" { return Ok(6) }
    if d == "saturday" { return Ok(7) }
    if d == "unmanaged" { return Ok(-1) }
    Err("invalid 'scheduled_day' value '" + d + "' (expected :every_day, a weekday or :unmanaged)")
}

fn want_reboot_with_users(params: Value) -> Result[int, string] {
    let r = common::param_str(params, "reboot_with_logged_on_users", "unmanaged")
    // NoAutoRebootWithLoggedOnUsers is inverted: 1 blocks the auto reboot.
    if r == "allowed" { return Ok(0) }
    if r == "blocked" { return Ok(1) }
    if r == "unmanaged" { return Ok(-1) }
    Err("invalid 'reboot_with_logged_on_users' value '" + r + "' (expected :allowed, :blocked or :unmanaged)")
}

fn scheduled_hour(params: Value) -> Result[int, string] {
    let h = common::param_int(params, "scheduled_hour", -1)
    if h == -1 { return Ok(-1) }
    if h < 0 || h > 23 { return Err("'scheduled_hour' must be 0-23 (or -1 to leave it unmanaged)") }
    Ok(h)
}

fn detection_hours(params: Value) -> Result[int, string] {
    let d = common::param_int(params, "detection_frequency_hours", -1)
    if d == -1 { return Ok(-1) }
    if d < 1 || d > 22 { return Err("'detection_frequency_hours' must be 1-22 (or -1 to leave it unmanaged)") }
    Ok(d)
}

// The wanted values in names() order; -1 leaves a value unmanaged.
fn wanted(params: Value) -> Result[List[int], string] {
    let detect = detection_hours(params)?
    // DetectionFrequency only takes effect with its companion flag set.
    let detect_flag = if detect == -1 { -1 } else { 1 }
    Ok([want_enabled(params)?, want_au_option(params)?, want_scheduled_day(params)?,
        scheduled_hour(params)?, want_reboot_with_users(params)?, detect, detect_flag])
}

// With ensure = :absent every value this resource owns is deleted, so the
// other params must be left unmanaged rather than silently ignored.
fn absent(params: Value) -> Result[bool, string] {
    if common::want_present(params)? { return Ok(false) }
    for w in wanted(params)? {
        if w != -1 { return Err("ensure = :absent removes the whole Automatic Updates policy; leave the other params unmanaged") }
    }
    Ok(true)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if absent(params)? {
        if common::any_value(common::au_key(), names())? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = wanted(params)?
    let n = names()
    for i in 0..n.len() {
        if !common::int_matches(common::au_key(), n[i], want[i])? { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if absent(params)? {
        common::delete_values(common::au_key(), names())?
        return Ok(ApplyResult::Success)
    }
    let want = wanted(params)?
    let n = names()
    for i in 0..n.len() { common::put_int(common::au_key(), n[i], want[i])? }
    Ok(ApplyResult::Success)
}
