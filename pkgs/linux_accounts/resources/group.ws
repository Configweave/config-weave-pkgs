use value
use shell
use common

fn group_exists(name: string) -> Result[bool, string] {
    Ok(shell::bash("getent group " + common::q(name) + " >/dev/null", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let exists = group_exists(name)?
    if !common::want_present(params)? {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if exists { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !common::want_present(params)? {
        if !group_exists(name)? { return Ok(ApplyResult::Success) }
        // fails while the group is still some user's primary group — order
        // the user's removal first with `requires`
        let out = shell::bash("groupdel " + common::q(name), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    let gid = common::param_int(params, "gid", 0)
    let gid_arg = if gid > 0 { " -g " + str(gid) } else { "" }
    let out = shell::bash("groupadd" + gid_arg + " " + common::q(name), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

