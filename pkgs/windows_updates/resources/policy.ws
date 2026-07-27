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

// The Automatic Updates policy key, the same one the "Configure Automatic
// Updates" Group Policy setting writes.
fn au_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" }

// Absent values read as the policy default rather than an error: an unset
// policy is "not configured", which Windows treats as the default.
fn reg_int(name: string, fallback: int) -> Result[int, string] {
    if let Some(v) = registry::read(au_key(), name)? {
        return Ok(v.as_int().unwrap_or(fallback))
    }
    Ok(fallback)
}

// Every enumerated param carries an :unmanaged member, so a playbook sets
// only the aspects it cares about and leaves the rest of the policy alone.
fn want_enabled(params: Value) -> Result[int, string] {
    let e = param_str(params, "enabled", "unmanaged")
    // NoAutoUpdate is inverted: 1 disables automatic updates.
    if e == "enabled" { return Ok(0) }
    if e == "disabled" { return Ok(1) }
    if e == "unmanaged" { return Ok(-1) }
    Err("invalid 'enabled' value '" + e + "' (expected :enabled, :disabled or :unmanaged)")
}

fn want_au_option(params: Value) -> Result[int, string] {
    let o = param_str(params, "au_option", "unmanaged")
    if o == "notify_download" { return Ok(2) }
    if o == "auto_download_notify_install" { return Ok(3) }
    if o == "auto_download_schedule_install" { return Ok(4) }
    if o == "allow_local_admin" { return Ok(5) }
    if o == "unmanaged" { return Ok(-1) }
    Err("invalid 'au_option' value '" + o + "' (expected :notify_download, :auto_download_notify_install, :auto_download_schedule_install, :allow_local_admin or :unmanaged)")
}

fn want_scheduled_day(params: Value) -> Result[int, string] {
    let d = param_str(params, "scheduled_day", "unmanaged")
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
    let r = param_str(params, "reboot_with_logged_on_users", "unmanaged")
    // NoAutoRebootWithLoggedOnUsers is inverted: 1 blocks the auto reboot.
    if r == "allowed" { return Ok(0) }
    if r == "blocked" { return Ok(1) }
    if r == "unmanaged" { return Ok(-1) }
    Err("invalid 'reboot_with_logged_on_users' value '" + r + "' (expected :allowed, :blocked or :unmanaged)")
}

fn scheduled_hour(params: Value) -> Result[int, string] {
    let h = param_int(params, "scheduled_hour", -1)
    if h == -1 { return Ok(-1) }
    if h < 0 || h > 23 { return Err("'scheduled_hour' must be 0-23 (or -1 to leave it unmanaged)") }
    Ok(h)
}

fn detection_hours(params: Value) -> Result[int, string] {
    let d = param_int(params, "detection_frequency_hours", -1)
    if d == -1 { return Ok(-1) }
    if d < 1 || d > 22 { return Err("'detection_frequency_hours' must be 1-22 (or -1 to leave it unmanaged)") }
    Ok(d)
}

// -1 is the unmanaged sentinel throughout, so both helpers no-op on it.
fn matches(name: string, want: int) -> Result[bool, string] {
    if want == -1 { return Ok(true) }
    Ok(reg_int(name, 0)? == want)
}

fn put(name: string, want: int) -> Result[unit, string] {
    if want == -1 { return Ok(()) }
    registry::write(au_key(), name, Value::Int(want), "dword")?
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    if !matches("NoAutoUpdate", want_enabled(params)?)? { return Ok(CheckResult::NotConfigured) }
    if !matches("AUOptions", want_au_option(params)?)? { return Ok(CheckResult::NotConfigured) }
    if !matches("ScheduledInstallDay", want_scheduled_day(params)?)? { return Ok(CheckResult::NotConfigured) }
    if !matches("ScheduledInstallTime", scheduled_hour(params)?)? { return Ok(CheckResult::NotConfigured) }
    if !matches("NoAutoRebootWithLoggedOnUsers", want_reboot_with_users(params)?)? { return Ok(CheckResult::NotConfigured) }
    if !matches("DetectionFrequency", detection_hours(params)?)? { return Ok(CheckResult::NotConfigured) }
    // DetectionFrequency only takes effect with its companion flag set.
    if detection_hours(params)? != -1 && reg_int("DetectionFrequencyEnabled", 0)? != 1 {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    registry::create_key(au_key())?
    put("NoAutoUpdate", want_enabled(params)?)?
    put("AUOptions", want_au_option(params)?)?
    put("ScheduledInstallDay", want_scheduled_day(params)?)?
    put("ScheduledInstallTime", scheduled_hour(params)?)?
    put("NoAutoRebootWithLoggedOnUsers", want_reboot_with_users(params)?)?
    put("DetectionFrequency", detection_hours(params)?)?
    if detection_hours(params)? != -1 {
        registry::write(au_key(), "DetectionFrequencyEnabled", Value::Int(1), "dword")?
    }
    Ok(ApplyResult::Success)
}
