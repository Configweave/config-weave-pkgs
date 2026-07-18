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

// stat lstats by default, so a symlink at either path compares as itself,
// not as its target.
fn same_inode(a: string, b: string) -> bool {
    let cmd = "[ \"$(stat -c '%d:%i' " + q(a) + " 2>/dev/null)\" = \"$(stat -c '%d:%i' " + q(b) + " 2>/dev/null)\" ]"
    if let Ok(out) = shell::bash(cmd, Value::Null) { out.success } else { false }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        // read_link probes a symlink itself (fs::exists follows it and lies
        // about dangling links); the exists probe catches hard links, which
        // are indistinguishable from plain files.
        if fs::read_link(p).is_ok() || fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let target = param_str(params, "target", "")
    if target == "" { return Err("missing 'target' parameter") }
    if param_bool(params, "hard", false) {
        // Missing target => NotConfigured, not Err: a required step's apply
        // may legitimately create it after this check runs.
        if !fs::is_file(target) { return Ok(CheckResult::NotConfigured) }
        if fs::read_link(p).is_ok() { return Ok(CheckResult::NotConfigured) }  // a symlink is never a hard link
        if fs::is_file(p) && same_inode(p, target) { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    if fs::read_link(p).unwrap_or("") == target { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        // deletes the link itself, never its target (dropping a hard link
        // only removes one name/refcount)
        if fs::read_link(p).is_ok() || fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let target = param_str(params, "target", "")
    if target == "" { return Err("missing 'target' parameter") }
    if param_bool(params, "hard", false) {
        if !fs::is_file(target) { return Err("hard link target does not exist: " + target) }
        fs::mkdir(path::parent(p))?
        if fs::read_link(p).is_ok() || fs::exists(p) { fs::delete(p)? }
        let out = shell::bash("ln " + q(target) + " " + q(p), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    fs::mkdir(path::parent(p))?
    if fs::exists(p) { fs::delete(p)? }
    fs::symlink(target, p)?
    Ok(ApplyResult::Success)
}
