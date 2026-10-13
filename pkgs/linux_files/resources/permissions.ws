use value
use fs
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    if !fs::exists(p) { return Err("path does not exist: " + p) }
    if common::attrs_ok(p, a)? {
        Ok(CheckResult::AlreadyConfigured)
    } else {
        Ok(CheckResult::NotConfigured)
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    common::apply_attrs(p, a)?
    Ok(ApplyResult::Success)
}
