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

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !shell::bash("id -u " + q(name) + " >/dev/null 2>&1", Value::Null)?.success { return Ok(CheckResult::NotConfigured) }
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
