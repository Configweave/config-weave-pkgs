use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
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

fn dropin_path(user: string) -> string { "/etc/sudoers.d/" + user }

fn rule_line(user: string, passwordless: bool, commands: string) -> string {
    let np = if passwordless { "NOPASSWD: " } else { "" }
    user + " ALL=(ALL:ALL) " + np + commands + "\n"
}

fn valid_name(user: string) -> Result[unit, string] {
    // sudo silently ignores sudoers.d files whose names contain '.' or '~'
    if user == "" { return Err("missing 'user' parameter") }
    if user.contains(".") || user.contains("~") || user.contains("/") {
        return Err("user '" + user + "' cannot name a sudoers.d drop-in ('.', '~' and '/' are not allowed)")
    }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let user = param_str(params, "user", "")
    valid_name(user)?
    let p = dropin_path(user)
    if !want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = rule_line(user, param_bool(params, "passwordless", false), param_str(params, "commands", "ALL"))
    if fs::is_file(p) && fs::read(p)? == want { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let user = param_str(params, "user", "")
    valid_name(user)?
    let p = dropin_path(user)
    if !want_present(params)? {
        if fs::is_file(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let want = rule_line(user, param_bool(params, "passwordless", false), param_str(params, "commands", "ALL"))
    fs::mkdir(path::parent(p))?
    fs::write(p, want)?
    let out = shell::bash("chmod 0440 " + q(p), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    if param_bool(params, "validate", true) && (fs::exists("/usr/sbin/visudo") || fs::exists("/usr/bin/visudo")) {
        let chk = shell::bash("visudo -cf " + q(p), Value::Null)?
        if !chk.success {
            // never leave an invalid drop-in behind — it bricks sudo entirely
            fs::delete(p)?
            return Err("visudo rejected the rule: " + chk.stderr.trim() + chk.stdout.trim())
        }
    }
    Ok(ApplyResult::Success)
}
