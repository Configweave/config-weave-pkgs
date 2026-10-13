use value
use log
use common

// safe.directory is multi-valued — several paths (and the literal "*") can
// be listed at once — so this adds and removes single entries instead of
// replacing the key, leaving any sibling entries untouched.
fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    let listed = common::cfg_get_all(params, "safe.directory")?.contains(p)
    if common::want_present(params)? == listed { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    let listed = common::cfg_get_all(params, "safe.directory")?.contains(p)
    if common::want_present(params)? {
        if !listed {
            log::info("adding safe.directory " + p)
            common::cfg_add(params, "safe.directory", p)?
        }
    } else if listed {
        log::info("removing safe.directory " + p)
        common::cfg_unset_value(params, "safe.directory", p)?
    }
    Ok(ApplyResult::Success)
}
