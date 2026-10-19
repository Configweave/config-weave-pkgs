use value
use fs
use log
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    if !common::want_present(params)? {
        common::guard_delete(p)?
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if fs::is_file(p) { return Err("'" + p + "' exists and is a file, not a directory") }
    if fs::is_dir(p) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    if !common::want_present(params)? {
        common::guard_delete(p)?
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        if fs::is_file(p) { return Err("'" + p + "' is a file; use windows_files.file with ensure = :absent") }
        log::info("deleting directory " + p)
        fs::delete_dir(p)?
        return Ok(ApplyResult::Success)
    }
    if fs::is_file(p) { return Err("'" + p + "' exists and is a file, not a directory") }
    log::info("creating directory " + p)
    fs::mkdir(p)?
    Ok(ApplyResult::Success)
}
