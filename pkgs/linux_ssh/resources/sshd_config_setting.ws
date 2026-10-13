use value
use common
use fs
use path
use shell

fn conf_path(key: string) -> string {
    "/etc/ssh/sshd_config.d/" + common::dropin_prefix() + key.to_lower() + ".conf"
}

// Before 10-, drop-ins were 50-config-weave-<key>.conf, which sorts after
// 50-cloud-init.conf and so lost to it. apply removes the old name.
fn legacy_path(key: string) -> string {
    "/etc/ssh/sshd_config.d/50-config-weave-" + key.to_lower() + ".conf"
}

fn desired(params: Value) -> Result[string, string] {
    let key = common::param_str(params, "key", "")
    let value = common::param_str(params, "value", "").trim()
    if value == "" { return Err("missing 'value' parameter") }
    Ok(key + " " + value + "\n")
}

fn validate(params: Value) -> Result[unit, string] {
    common::valid_option_key(common::param_str(params, "key", ""), ["match", "include"])?
    common::one_line("value", common::param_str(params, "value", ""))?
    if common::want_present(params)? { let d = desired(params)? }
    Ok(())
}

// The sshd binary when validation is on and sshd is installed, else "".
fn sshd_bin(params: Value) -> string {
    if !common::param_bool(params, "validate", true) { return "" }
    for p in ["/usr/sbin/sshd", "/usr/bin/sshd", "/usr/local/sbin/sshd"] { if fs::is_file(p) { return p } }
    ""
}

// The lines `sshd -T` prints for `key` (lowercased by sshd) with config `f`.
fn effective(sshd: string, f: string, key: string) -> Result[List[string], string] {
    let out = shell::bash(common::q(sshd) + " -T -f " + common::q(f), Value::Null)?
    if !out.success { return Err(common::cmd_err("sshd -T -f " + f, out)) }
    let k = key.to_lower()
    let lines = []
    for line in out.stdout.split("\n") {
        let t = line.trim()
        if t.to_lower().starts_with(k + " ") { lines.push(t) }
    }
    Ok(lines)
}

// Whether the effective configuration carries the wanted value. sshd -T
// normalises values (2m prints as 120, without-password as
// prohibit-password), so the wanted line is normalised by the same sshd
// from a config holding only that line. Every normalised line must be in
// effect: for a multi-valued option (AcceptEnv) other files may add more.
fn in_effect(sshd: string, key: string, line: string) -> Result[bool, string] {
    let tmp = fs::temp_file()?
    fs::write(tmp, line)?
    let want = effective(sshd, tmp, key)
    fs::delete(tmp).unwrap_or(())
    let have = effective(sshd, "/etc/ssh/sshd_config", key)?
    for w in want? { if !have.contains(w) { return Ok(false) } }
    Ok(true)
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let key = common::param_str(params, "key", "")
    let p = conf_path(key)
    if fs::is_file(legacy_path(key)) { return Ok(CheckResult::NotConfigured) }
    if !common::want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = desired(params)?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if let Ok(t) = fs::read(p) { if t != want { return Ok(CheckResult::NotConfigured) } } else { return Ok(CheckResult::NotConfigured) }
    let sshd = sshd_bin(params)
    if sshd != "" && !in_effect(sshd, key, want)? {
        return Err(common::shadowed(key, p))
    }
    Ok(CheckResult::AlreadyConfigured)
}

// Restore the drop-in's previous content (or remove it) after sshd -t
// rejected the new one: an invalid file left in place would read as
// converged next run, and stops sshd from starting.
fn restore(p: string, before: Option[string]) -> Result[unit, string] {
    if let Some(t) = before { return fs::write(p, t) }
    if fs::is_file(p) { fs::delete(p)? }
    Ok(())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let key = common::param_str(params, "key", "")
    let p = conf_path(key)
    let legacy = legacy_path(key)
    let sshd = sshd_bin(params)
    let before = if fs::is_file(p) { if let Ok(t) = fs::read(p) { Some(t) } else { None } } else { None }
    if common::want_present(params)? {
        let want = desired(params)?
        fs::mkdir(path::parent(p))?
        fs::write(p, want)?
        if sshd != "" {
            let out = shell::bash(common::q(sshd) + " -t -f /etc/ssh/sshd_config", Value::Null)?
            if !out.success {
                restore(p, before)?
                return Err(common::cmd_err("sshd -t rejected " + key + " " + want.trim() + "; the drop-in was restored", out))
            }
            if !in_effect(sshd, key, want)? {
                restore(p, before)?
                return Err(common::shadowed(key, p))
            }
        }
    } else if fs::is_file(p) {
        fs::delete(p)?
    }
    if fs::is_file(legacy) { fs::delete(legacy)? }
    if common::param_bool(params, "reload", false) { common::reload_sshd()? }
    Ok(ApplyResult::Success)
}
