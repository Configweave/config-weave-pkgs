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
    if p == "" { return Err("missing 'path' parameter") }
    let body = template::render(common::param_str(params, "template", ""), vars(params))?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if fs::read(p)? != body { return Ok(CheckResult::NotConfigured) }
    if !common::attrs_ok(p, common::param_str(params, "mode", ""), common::param_str(params, "owner", ""), common::param_str(params, "group", ""))? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    let body = template::render(common::param_str(params, "template", ""), vars(params))?
    log::info("rendering " + p)
    fs::mkdir(path::parent(p))?
    fs::write(p, body)?
    common::apply_attrs(p, common::param_str(params, "mode", ""), common::param_str(params, "owner", ""), common::param_str(params, "group", ""))?
    Ok(ApplyResult::Success)
}
