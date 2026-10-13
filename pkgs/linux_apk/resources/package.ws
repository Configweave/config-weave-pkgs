use value
use fs
use shell
use common

// The package an apk dependency spec names: `tree`, `tree@testing`,
// `tree=2.1.1-r0`, `tree>2`, `tree~2.1` all name tree.
fn base_name(spec: string) -> string {
    let cut = spec.len()
    for sep in ["@", "=", "<", ">", "~"] {
        if let Some(i) = spec.find(sep) { if i < cut { cut = i } }
    }
    spec.slice(0, cut)
}

// /etc/apk/world holds exactly what was asked for, one spec per line, as
// `apk add` wrote it. A package that is only installed as another's
// dependency is not in it, and goes when that package goes.
fn in_world(spec: string) -> Result[bool, string] {
    if !fs::is_file("/etc/apk/world") { return Ok(false) }
    for l in fs::read("/etc/apk/world")?.split("\n") {
        if l.trim() == spec { return Ok(true) }
    }
    Ok(false)
}

// apk info -e honours a version constraint and ignores a repository tag.
fn installed(spec: string) -> Result[bool, string] {
    Ok(shell::bash("apk info -e " + common::q(spec) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    if base_name(name) == "" { return Err("invalid 'name' '" + name + "': no package name before the tag or constraint") }
    Ok(name)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let ok = if common::want_present(params)? {
        in_world(name)? && installed(name)?
    } else {
        !installed(base_name(name))?
    }
    if ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    if common::want_present(params)? {
        common::output("apk add", common::apk("add " + common::q(name)))?
        return Ok(ApplyResult::Success)
    }
    let base = base_name(name)
    let flags = if common::param_bool(params, "remove_dependents", false) { "-r " } else { "" }
    let out = common::output("apk del", common::apk("del " + flags + common::q(base)))?
    // apk del exits 0 when another installed package still needs this one:
    // it drops the name from world and leaves the package installed.
    if installed(base)? {
        return Err("apk del left " + base + " installed (set remove_dependents = true to remove what needs it): " + out.stdout.trim())
    }
    Ok(ApplyResult::Success)
}
