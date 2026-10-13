use value
use fs
use path
use common

fn repo_path(name: string) -> string {
    "/etc/yum.repos.d/" + name + ".repo"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = repo_path(name)
    if !common::want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    if fs::is_file(p) && fs::read(p)? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
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
