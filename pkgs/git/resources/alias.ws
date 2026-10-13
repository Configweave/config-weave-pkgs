use value
use log
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let have = common::cfg_get(params, "alias." + name)?
    if !common::want_present(params)? {
        if have.is_none() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let command = common::param_str(params, "command", "")
    if command == "" { return Err("missing 'command' parameter") }
    // Compared literally, not through norm(): an alias is arbitrary text.
    if have.unwrap_or("") == command { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let key = "alias." + name
    if !common::want_present(params)? {
        log::info("removing " + key)
        common::cfg_unset(params, key)?
        return Ok(ApplyResult::Success)
    }
    let command = common::param_str(params, "command", "")
    if command == "" { return Err("missing 'command' parameter") }
    log::info("setting " + key)
    common::cfg_set(params, key, command)?
    Ok(ApplyResult::Success)
}
