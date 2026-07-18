use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn group_exists(name: string) -> Result[bool, string] {
    Ok(shell::bash("getent group " + q(name) + " >/dev/null", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let exists = group_exists(name)?
    if !want_present(params)? {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if exists { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        if !group_exists(name)? { return Ok(ApplyResult::Success) }
        // fails while the group is still some user's primary group — order
        // the user's removal first with `requires`
        let out = shell::bash("groupdel " + q(name), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    let gid = param_int(params, "gid", 0)
    let gid_arg = if gid > 0 { " -g " + str(gid) } else { "" }
    let out = shell::bash("groupadd" + gid_arg + " " + q(name), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

