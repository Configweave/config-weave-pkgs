use value
use fs
use path
use shell
use common

// sudo's includedir skips any file whose name contains '.' or ends in '~',
// so a dotted user (john.doe) gets a drop-in named with '_' (john_doe); the
// rule inside still names the real user.
fn dropin_path(user: string) -> string {
    "/etc/sudoers.d/" + user.replace(".", "_")
}

// A name sudo ignores (it contains '.'), so a half-written or invalid rule
// is never live.
fn temp_path(p: string) -> string { path::parent(p) + "/." + path::filename(p) + ".cw-tmp" }

fn rule_line(user: string, passwordless: bool, commands: string) -> string {
    let np = if passwordless { "NOPASSWD: " } else { "" }
    user + " ALL=(ALL:ALL) " + np + commands + "\n"
}

// `user` is a single sudoers token: an account name, or %group. Anything
// else (whitespace, '=', ',', '#', a line break) would change the rule.
fn valid_user(user: string) -> Result[unit, string] {
    if user == "" { return Err("missing 'user' parameter") }
    let name = if user.starts_with("%") { user.slice(1, user.len()) } else { user }
    common::valid_account("user", name)
}

fn valid_commands(commands: string) -> Result[unit, string] {
    common::one_line("commands", commands)?
    if commands.trim() == "" { return Err("'commands' must not be empty") }
    if commands.trim().ends_with("\\") { return Err("'commands' must not end in '\\' (a sudoers line continuation)") }
    Ok(())
}

fn desired(params: Value) -> Result[string, string] {
    let user = common::param_str(params, "user", "")
    let commands = common::param_str(params, "commands", "ALL")
    valid_commands(commands)?
    Ok(rule_line(user, common::param_bool(params, "passwordless", false), commands))
}

// Two dotted names can map to one file (a.b and a_b); refuse to take over
// a drop-in that holds another user's rule.
fn guard_collision(p: string, user: string) -> Result[unit, string] {
    if !user.contains(".") || !fs::is_file(p) { return Ok(()) }
    let first = fs::read(p).unwrap_or("").trim().split(" ").get(0).unwrap_or("")
    if first != "" && first != user { return Err(p + " holds a rule for " + first + ", not " + user) }
    Ok(())
}

// sudo refuses (or ignores) a drop-in that is writable by anyone but root,
// so the mode and owner are part of the state.
fn attrs_ok(p: string) -> Result[bool, string] {
    let out = shell::bash("stat -c '%a %u %g' -- " + common::q(p), Value::Null)?
    if !out.success { return Err(common::cmd_err("stat " + p, out)) }
    Ok(out.stdout.trim() == "440 0 0")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let user = common::param_str(params, "user", "")
    valid_user(user)?
    let p = dropin_path(user)
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = desired(params)?
    guard_collision(p, user)?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    // unreadable (non-UTF-8) content is drift, not an error
    if fs::read(p).unwrap_or("") != want { return Ok(CheckResult::NotConfigured) }
    if attrs_ok(p)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let user = common::param_str(params, "user", "")
    valid_user(user)?
    let p = dropin_path(user)
    if !common::want_present(params)? {
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let want = desired(params)?
    guard_collision(p, user)?
    fs::mkdir(path::parent(p))?
    // Build the rule under a name sudo ignores, secure and validate it
    // there, and only then rename it over the live drop-in: an invalid rule
    // never goes live, and a valid old rule stays in place on failure.
    let tmp = temp_path(p)
    fs::write(tmp, want)?
    let secured = common::run("securing " + tmp, "chown 0:0 -- " + common::q(tmp) + " && chmod 0440 -- " + common::q(tmp))
    if let Err(e) = secured {
        fs::delete(tmp).unwrap_or(())
        return Err(e)
    }
    if common::param_bool(params, "validate", true) && (fs::exists("/usr/sbin/visudo") || fs::exists("/usr/bin/visudo")) {
        let chk = shell::bash("visudo -cf " + common::q(tmp), Value::Null)?
        if !chk.success {
            fs::delete(tmp).unwrap_or(())
            return Err(common::cmd_err("visudo rejected the rule for " + user, chk))
        }
    }
    if let Err(e) = fs::move(tmp, p) {
        fs::delete(tmp).unwrap_or(())
        return Err(e)
    }
    Ok(ApplyResult::Success)
}
