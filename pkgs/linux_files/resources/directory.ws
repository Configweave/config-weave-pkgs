use value
use fs
use log
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    if !common::want_present(params)? {
        common::refuse_critical("path", p)?
        if common::lexists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_dir(p) { return Ok(CheckResult::NotConfigured) }
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
        common::refuse_critical("path", p)?
        if !common::lexists(p) { return Ok(ApplyResult::Success) }
        if fs::read_link(p).is_ok() { return Err("path is a symlink; use linux_files.symlink with ensure = :absent") }
        if !fs::is_dir(p) { return Err("path is not a directory; use linux_files.file with ensure = :absent") }
        log::info("deleting directory " + p)
        fs::delete_dir(p)?
        return Ok(ApplyResult::Success)
    }
    if !fs::is_dir(p) {
        log::info("creating directory " + p)
        fs::mkdir(p)?
    }
    common::apply_attrs(p, a)?
    Ok(ApplyResult::Success)
}
