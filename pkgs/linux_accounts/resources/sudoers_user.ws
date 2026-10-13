use value
use fs
use path
use shell
use common

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
    let user = common::param_str(params, "user", "")
    valid_name(user)?
    let p = dropin_path(user)
    if !common::want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = rule_line(user, common::param_bool(params, "passwordless", false), common::param_str(params, "commands", "ALL"))
    if fs::is_file(p) && fs::read(p)? == want { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let user = common::param_str(params, "user", "")
    valid_name(user)?
    let p = dropin_path(user)
    if !common::want_present(params)? {
        if fs::is_file(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let want = rule_line(user, common::param_bool(params, "passwordless", false), common::param_str(params, "commands", "ALL"))
    fs::mkdir(path::parent(p))?
    fs::write(p, want)?
    let out = shell::bash("chmod 0440 " + common::q(p), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    if common::param_bool(params, "validate", true) && (fs::exists("/usr/sbin/visudo") || fs::exists("/usr/bin/visudo")) {
        let chk = shell::bash("visudo -cf " + common::q(p), Value::Null)?
        if !chk.success {
            // never leave an invalid drop-in behind — it bricks sudo entirely
            fs::delete(p)?
            return Err("visudo rejected the rule: " + chk.stderr.trim() + chk.stdout.trim())
        }
    }
    Ok(ApplyResult::Success)
}
