use value
use common
use config_file

// The setting is DisableImplicitWinCompat, so the friendlier
// implicit_win_compat param is its inverse: :enabled means disable = false.
fn compat_disabled(params: Value) -> Result[Option[bool], string] {
    let want = common::param_str(params, "implicit_win_compat", "unmanaged")
    if want == "unmanaged" { return Ok(None) }
    if want == "enabled" { return Ok(Some(false)) }
    if want == "disabled" { return Ok(Some(true)) }
    Err("invalid 'implicit_win_compat' value '" + want + "' (expected :enabled, :disabled or :unmanaged)")
}

// Returns the document the params describe, so check and apply cannot drift.
fn desired_doc(params: Value, doc: Value) -> Result[Value, string] {
    let updated = doc
    if let Some(disable) = compat_disabled(params)? {
        updated = config_file::put(updated, "DisableImplicitWinCompat", Value::Bool(disable))
    }
    let manage = common::param_bool(params, "manage_lists", false)
    let deny = common::param_list(params, "deny_list")
    if manage || !deny.is_empty() {
        updated = config_file::put(updated, "WindowsPowerShellCompatibilityModuleDenyList", config_file::string_list(deny))
    }
    let no_clobber = common::param_list(params, "no_clobber_list")
    if manage || !no_clobber.is_empty() {
        updated = config_file::put(updated, "WindowsPowerShellCompatibilityNoClobberModuleList", config_file::string_list(no_clobber))
    }
    Ok(updated)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let resolved = config_file::config_path(params)?
    if resolved.is_none() { return Ok(CheckResult::NotConfigured) }
    // An unreadable file is drift; apply says why it cannot rewrite it.
    let read = config_file::read_doc(resolved.unwrap())
    if read.is_err() { return Ok(CheckResult::NotConfigured) }
    let doc = read.unwrap()
    if config_file::same_value(desired_doc(params, doc)?, doc) { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = config_file::require_config_path(params)?
    let doc = config_file::read_doc(file)?
    config_file::write_doc(file, desired_doc(params, doc)?)?
    Ok(ApplyResult::Success)
}
