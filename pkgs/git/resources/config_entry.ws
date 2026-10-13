use value
use log
use common

// The escape hatch for the ~900 config variables with no typed resource,
// and the only way to remove a key a section resource can set.
//
// Reads go through --get-all rather than --get: --get exits 2 on a
// multi-valued key, and "converged" for a --replace-all write means
// exactly one value, which is what the length check asserts.
fn check(params: Value) -> Result[CheckResult, string] {
    let key = common::param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    let value = common::param_str(params, "value", "")
    let current = common::cfg_get_all(params, key)?
    if !common::want_present(params)? {
        // With a value, remove just that occurrence; without, remove them all.
        if value == "" {
            if current.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
            return Ok(CheckResult::NotConfigured)
        }
        if current.contains(value) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if value == "" { return Err("missing 'value' parameter") }
    if current.len() == 1 && common::norm(current.get(0).unwrap_or("")) == common::norm(value) {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = common::param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    let value = common::param_str(params, "value", "")
    if !common::want_present(params)? {
        log::info("removing " + key)
        if value == "" { common::cfg_unset(params, key)? } else { common::cfg_unset_value(params, key, value)? }
        return Ok(ApplyResult::Success)
    }
    if value == "" { return Err("missing 'value' parameter") }
    log::info("setting " + key + " = " + value)
    common::cfg_set(params, key, value)?
    Ok(ApplyResult::Success)
}
