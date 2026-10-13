use value
use common
use fs
use path

// One drop-in per option keeps removal trivial and files independent.
fn conf_path(key: string) -> string {
    "/etc/ssh/ssh_config.d/50-config-weave-" + key.to_lower() + ".conf"
}

fn desired(params: Value) -> Result[string, string] {
    let key = common::param_str(params, "key", "")
    let value = common::param_str(params, "value", "")
    if value == "" { return Err("missing 'value' parameter") }
    Ok("Host " + common::param_str(params, "host", "*") + "\n    " + key + " " + value + "\n")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let key = common::param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    let p = conf_path(key)
    if !common::want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if fs::is_file(p) && fs::read(p)? == desired(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = common::param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    let p = conf_path(key)
    if !common::want_present(params)? {
        if fs::is_file(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    fs::mkdir(path::parent(p))?
    fs::write(p, desired(params)?)?
    Ok(ApplyResult::Success)
}
