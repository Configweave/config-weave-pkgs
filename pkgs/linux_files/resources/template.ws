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

fn render(params: Value) -> Result[string, string] {
    let body = common::param_str(params, "template", "")
    if body == "" { return Err("missing 'template' parameter (required when ensure is :present)") }
    template::render(body, vars(params))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    if !common::want_present(params)? {
        if common::lexists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let body = render(params)?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if !common::content_is(p, body) { return Ok(CheckResult::NotConfigured) }
    if !common::attrs_ok(p, a)? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    if !common::want_present(params)? {
        if !common::lexists(p) { return Ok(ApplyResult::Success) }
        if fs::read_link(p).is_err() && fs::is_dir(p) { return Err("path is a directory; use linux_files.directory with ensure = :absent") }
        log::info("deleting " + p)
        fs::delete(p)?
        return Ok(ApplyResult::Success)
    }
    let body = render(params)?
    log::info("rendering " + p)
    fs::mkdir(path::parent(p))?
    let tmp = common::tmp_sibling(p)
    fs::write(tmp, body)?
    common::install_tmp(tmp, p)?
    common::apply_attrs(p, a)?
    Ok(ApplyResult::Success)
}
