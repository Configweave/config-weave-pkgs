use value
use shell
use common

fn user_exists(name: string) -> Result[bool, string] {
    Ok(shell::bash("id -u " + common::q(name) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !common::want_present(params)? {
        if user_exists(name)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !user_exists(name)? { return Ok(CheckResult::NotConfigured) }
    let group = common::param_str(params, "group", "")
    if group != "" && !shell::bash("id -gn " + common::q(name) + " | grep -Fx " + common::q(group) + " >/dev/null", Value::Null)?.success {
        return Ok(CheckResult::NotConfigured)
    }
    let home = common::param_str(params, "home", "")
    if home != "" && !shell::bash("getent passwd " + common::q(name) + " | cut -d: -f6 | grep -Fx " + common::q(home) + " >/dev/null", Value::Null)?.success {
        return Ok(CheckResult::NotConfigured)
    }
    let sh = common::param_str(params, "shell", "")
    if sh != "" && !shell::bash("getent passwd " + common::q(name) + " | cut -d: -f7 | grep -Fx " + common::q(sh) + " >/dev/null", Value::Null)?.success {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !common::want_present(params)? {
        if !user_exists(name)? { return Ok(ApplyResult::Success) }
        let flag = if common::param_bool(params, "remove_home", false) { " -r" } else { "" }
        let out = shell::bash("userdel" + flag + " " + common::q(name), Value::Null)?
        if !out.success {
            // userdel -r exits non-zero on an already-missing home or mail
            // spool; trust the re-probe — gone means done
            if !user_exists(name)? { return Ok(ApplyResult::Success) }
            return Err(out.stderr.trim())
        }
        return Ok(ApplyResult::Success)
    }
    let uid = common::param_int(params, "uid", 0)
    let group = common::param_str(params, "group", "")
    let home = common::param_str(params, "home", "")
    let sh = common::param_str(params, "shell", "")
    let sys = common::param_bool(params, "system", false)
    let exists = shell::bash("id -u " + common::q(name) + " >/dev/null 2>&1", Value::Null)?.success
    if !exists {
        let cmd = "useradd -m"
        if uid > 0 { cmd = cmd + " -u " + str(uid) }
        if group != "" { cmd = cmd + " -g " + common::q(group) }
        if home != "" { cmd = cmd + " -d " + common::q(home) }
        if sh != "" { cmd = cmd + " -s " + common::q(sh) }
        if sys { cmd = cmd + " --system" }
        cmd = cmd + " " + common::q(name)
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    } else {
        let cmd = "usermod"
        if group != "" { cmd = cmd + " -g " + common::q(group) }
        if home != "" { cmd = cmd + " -d " + common::q(home) + " -m" }
        if sh != "" { cmd = cmd + " -s " + common::q(sh) }
        cmd = cmd + " " + common::q(name)
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}
