use value
use fs
use path
use common

fn repo_path(name: string) -> string {
    "/etc/yum.repos.d/" + name + ".repo"
}

// A file that cannot be read as text holds something other than content.
fn holds(p: string, content: string) -> bool {
    if !fs::is_file(p) { return false }
    if let Ok(text) = fs::read(p) { text == content } else { false }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::file_name("name", name)?
    let p = repo_path(name)
    if !common::want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    if holds(p, content) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    common::file_name("name", name)?
    let p = repo_path(name)
    if !common::want_present(params)? {
        if fs::is_file(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    fs::mkdir(path::parent(p))?
    fs::write(p, content)?
    Ok(ApplyResult::Success)
}
