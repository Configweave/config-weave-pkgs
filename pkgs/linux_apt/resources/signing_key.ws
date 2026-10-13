use value
use fs
use path
use shell
use common

// The ASCII-armored key is the source of truth (content-compared); a
// binary .gpg keyring is derived from it when dearmor is requested.
fn asc_path(name: string) -> string { "/etc/apt/keyrings/" + name + ".asc" }
fn gpg_path(name: string) -> string { "/etc/apt/keyrings/" + name + ".gpg" }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !common::want_present(params)? {
        if fs::is_file(asc_path(name)) || fs::is_file(gpg_path(name)) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    let asc = asc_path(name)
    if !fs::is_file(asc) || fs::read(asc)? != content { return Ok(CheckResult::NotConfigured) }
    if common::param_bool(params, "dearmor", true) && !fs::is_file(gpg_path(name)) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !common::want_present(params)? {
        if fs::is_file(asc_path(name)) { fs::delete(asc_path(name))? }
        if fs::is_file(gpg_path(name)) { fs::delete(gpg_path(name))? }
        return Ok(ApplyResult::Success)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    let asc = asc_path(name)
    fs::mkdir(path::parent(asc))?
    fs::write(asc, content)?
    if common::param_bool(params, "dearmor", true) {
        let out = shell::bash("gpg --batch --yes --dearmor -o " + common::q(gpg_path(name)) + " " + common::q(asc), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}
