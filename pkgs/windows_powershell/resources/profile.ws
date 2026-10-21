use value
use fs
use http
use common
use profiles
use user_tree

fn desired_content(params: Value) -> Result[string, string] {
    let source = common::param_str(params, "source", "")
    if source == "" { return Ok(common::param_str(params, "content", "")) }
    if source.starts_with("http://") || source.starts_with("https://") {
        let response = http::get(source, Value::Null)?
        if response.status < 200 || response.status >= 300 {
            return Err("GET " + source + " returned " + str(response.status))
        }
        return Ok(profiles::strip_bom(response.body))
    }
    if !fs::is_file(source) { return Err("source file '" + source + "' does not exist") }
    Ok(profiles::strip_bom(fs::read(source)?))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    // A link in a user's tree is an error here, not drift: apply refuses it
    // too, so it could never converge.
    let resolved = profiles::guarded_profile_path(params)?
    if resolved.is_none() {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let file = resolved.unwrap()
    let root = profiles::user_root(params)
    if !present {
        if user_tree::exists(root, file)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // A profile that is not UTF-8 is drift: apply replaces it outright.
    let read = profiles::read_text(params, file)
    if read.is_err() { return Ok(CheckResult::NotConfigured) }
    let current = read.unwrap()
    if current.is_none() { return Ok(CheckResult::NotConfigured) }
    let text = current.unwrap()
    let wanted = desired_content(params)?
    if profiles::wants_bom(params) && wanted != "" && !profiles::has_bom(text) { return Ok(CheckResult::NotConfigured) }
    if profiles::strip_bom(text) == wanted { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = profiles::require_profile_path(params)?
    if !common::want_present(params)? {
        user_tree::delete(profiles::user_root(params), file)?
        return Ok(ApplyResult::Success)
    }
    // Written without reading the old file first, so the guard in
    // require_profile_path and write_text is all that keeps a link out.
    let content = desired_content(params)?
    profiles::write_text(params, file, content, profiles::wants_bom(params) && content != "")?
    Ok(ApplyResult::Success)
}
