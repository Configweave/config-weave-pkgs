use value
use fs
use log
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_dir(p) { return Ok(CheckResult::NotConfigured) }
    if !common::attrs_ok(p, common::param_str(params, "mode", ""), common::param_str(params, "owner", ""), common::param_str(params, "group", ""))? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !common::want_present(params)? {
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        if !fs::is_dir(p) { return Err("path is not a directory; use linux_files.file with ensure = :absent") }
        log::info("deleting directory " + p)
        fs::delete_dir(p)?
        return Ok(ApplyResult::Success)
    }
    log::info("creating directory " + p)
    fs::mkdir(p)?
    common::apply_attrs(p, common::param_str(params, "mode", ""), common::param_str(params, "owner", ""), common::param_str(params, "group", ""))?
    Ok(ApplyResult::Success)
}
