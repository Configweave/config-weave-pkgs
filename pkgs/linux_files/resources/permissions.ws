use value
use fs
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !fs::exists(p) { return Err("path does not exist: " + p) }
    if common::attrs_ok(p, common::param_str(params, "mode", ""), common::param_str(params, "owner", ""), common::param_str(params, "group", ""))? {
        Ok(CheckResult::AlreadyConfigured)
    } else {
        Ok(CheckResult::NotConfigured)
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    common::apply_attrs(p, common::param_str(params, "mode", ""), common::param_str(params, "owner", ""), common::param_str(params, "group", ""))?
    Ok(ApplyResult::Success)
}
