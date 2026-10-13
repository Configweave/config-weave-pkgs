use value
use fs
use template
use log
use common

fn vars(params: Value) -> Value {
    if let Some(v) = params.get("vars") { return v }
    Value::Null
}

// The rendered file. An empty template is an error rather than an empty
// file: it is almost always a missing param, not a wish for zero bytes.
fn rendered(params: Value) -> Result[string, string] {
    let body = common::param_str(params, "template", "")
    if body == "" { return Err("'template' is required when ensure is :present (use windows_files.file for an empty file)") }
    common::with_line_endings(params, template::render(body, vars(params))?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    if !common::want_present(params)? {
        if fs::exists(p) || fs::read_link(p).is_ok() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // Rendering in `check` is what makes a variable change count as drift:
    // the file is compared against what the template produces now, not
    // against what it produced when it was written.
    let body = rendered(params)?
    if fs::is_dir(p) { return Err("'" + p + "' is a directory, not a file") }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if !common::content_is(p, body) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    if !common::want_present(params)? {
        if !fs::exists(p) && fs::read_link(p).is_err() { return Ok(ApplyResult::Success) }
        if fs::read_link(p).is_err() && fs::is_dir(p) { return Err("'" + p + "' is a directory; use windows_files.directory with ensure = :absent") }
        log::info("deleting " + p)
        fs::delete(p)?
        return Ok(ApplyResult::Success)
    }
    let body = rendered(params)?
    log::info("rendering " + p)
    common::write_content(p, body)?
    Ok(ApplyResult::Success)
}
