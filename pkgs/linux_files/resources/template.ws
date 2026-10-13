use value
use fs
use path
use template
use log
use common

fn vars(params: Value) -> Value {
    if let Some(v) = params.get("vars") { return v }
    Value::Null
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    let body = template::render(common::param_str(params, "template", ""), vars(params))?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if fs::read(p)? != body { return Ok(CheckResult::NotConfigured) }
    if !common::attrs_ok(p, a)? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    let body = template::render(common::param_str(params, "template", ""), vars(params))?
    log::info("rendering " + p)
    fs::mkdir(path::parent(p))?
    fs::write(p, body)?
    common::apply_attrs(p, a)?
    Ok(ApplyResult::Success)
}
