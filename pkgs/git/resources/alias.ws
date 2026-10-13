use value
use log
use common

// The alias name is the last part of the key alias.<name>, so it follows
// git's variable-name rules: no dots, spaces or line breaks.
fn alias_name(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if name.contains(".") { return Err("invalid alias name '" + name + "': it may not contain '.'") }
    common::check_key("alias." + name)?
    Ok(name)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = alias_name(params)?
    let have = common::cfg_get_all(params, "alias." + name)?
    if !common::want_present(params)? {
        if have.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let command = common::param_str(params, "command", "")
    if command == "" { return Err("missing 'command' parameter") }
    // Exactly one definition, since apply writes with --replace-all.
    // Compared literally, not through fold_words(): an alias is arbitrary text.
    if have.len() == 1 && have.get(0).unwrap_or("") == command { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = alias_name(params)?
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
