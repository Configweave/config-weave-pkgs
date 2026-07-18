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

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn user_exists(name: string) -> Result[bool, string] {
    Ok(shell::bash("id -u " + q(name) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        if user_exists(name)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !user_exists(name)? { return Ok(CheckResult::NotConfigured) }
    let group = param_str(params, "group", "")
    if group != "" && !shell::bash("id -gn " + q(name) + " | grep -Fx " + q(group) + " >/dev/null", Value::Null)?.success {
        return Ok(CheckResult::NotConfigured)
    }
    let home = param_str(params, "home", "")
    if home != "" && !shell::bash("getent passwd " + q(name) + " | cut -d: -f6 | grep -Fx " + q(home) + " >/dev/null", Value::Null)?.success {
        return Ok(CheckResult::NotConfigured)
    }
    let sh = param_str(params, "shell", "")
    if sh != "" && !shell::bash("getent passwd " + q(name) + " | cut -d: -f7 | grep -Fx " + q(sh) + " >/dev/null", Value::Null)?.success {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        if !user_exists(name)? { return Ok(ApplyResult::Success) }
        let flag = if param_bool(params, "remove_home", false) { " -r" } else { "" }
        let out = shell::bash("userdel" + flag + " " + q(name), Value::Null)?
        if !out.success {
            // userdel -r exits non-zero on an already-missing home or mail
            // spool; trust the re-probe — gone means done
            if !user_exists(name)? { return Ok(ApplyResult::Success) }
            return Err(out.stderr.trim())
        }
        return Ok(ApplyResult::Success)
    }
    let uid = param_int(params, "uid", 0)
    let group = param_str(params, "group", "")
    let home = param_str(params, "home", "")
    let sh = param_str(params, "shell", "")
    let sys = param_bool(params, "system", false)
    let exists = shell::bash("id -u " + q(name) + " >/dev/null 2>&1", Value::Null)?.success
    if !exists {
        let cmd = "useradd -m"
        if uid > 0 { cmd = cmd + " -u " + str(uid) }
        if group != "" { cmd = cmd + " -g " + q(group) }
        if home != "" { cmd = cmd + " -d " + q(home) }
        if sh != "" { cmd = cmd + " -s " + q(sh) }
        if sys { cmd = cmd + " --system" }
        cmd = cmd + " " + q(name)
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    } else {
        let cmd = "usermod"
        if group != "" { cmd = cmd + " -g " + q(group) }
        if home != "" { cmd = cmd + " -d " + q(home) + " -m" }
        if sh != "" { cmd = cmd + " -s " + q(sh) }
        cmd = cmd + " " + q(name)
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}
