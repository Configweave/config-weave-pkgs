use value
use common
use fs
use path
use shell

// The key's identity is its type and base64 blob: options and comment can
// differ between two lines that authorize the same key.
fn identity(line: string) -> string {
    if let Some(k) = common::parse_key(line) { return k.get(1).unwrap_or("") + " " + k.get(2).unwrap_or("") }
    ""
}

// The wanted key, validated: one line that parses as an authorized_keys
// entry. Returns the trimmed line.
fn wanted_key(params: Value) -> Result[string, string] {
    let key = common::param_str(params, "key", "").trim()
    if key == "" { return Err("missing 'key' parameter") }
    common::one_line("key", key)?
    if common::parse_key(key).is_none() {
        return Err("'key' is not an authorized_keys line ([options] type base64 [comment])")
    }
    Ok(key)
}

fn ssh_dir(params: Value, user: string) -> Result[string, string] {
    let h = common::param_str(params, "home", "")
    if h != "" {
        common::valid_home(h)?
        return Ok(path::join(h, ".ssh"))
    }
    Ok(path::join(common::user_home(user)?, ".ssh"))
}

// The file with every line for this key replaced by the wanted line (the
// first occurrence) or dropped (later ones, or all of them when `want` is
// empty). Everything else, blank lines included, is kept as it was.
fn rewrite(text: string, id: string, want: string) -> string {
    let lines = if text == "" { [] } else { text.split("\n") }
    if text.ends_with("\n") { let trailing = lines.pop() }
    let out = []
    let done = want == ""
    for line in lines {
        if identity(line) == id {
            if !done {
                out.push(want)
                done = true
            }
        } else {
            out.push(line)
        }
    }
    if !done { out.push(want) }
    if out.is_empty() { "" } else { out.join("\n") + "\n" }
}

fn read_keys(p: string) -> Result[string, string] {
    if !fs::is_file(p) { return Ok("") }
    fs::read(p)
}

// sshd's StrictModes rejects keys in a group- or world-writable .ssh or
// authorized_keys, or ones not owned by the user; apply sets 700/600 and
// the user as owner, and check compares exactly that.
fn attrs_ok(dir: string, p: string, uid: string) -> Result[bool, string] {
    let d = common::stat_line(dir)?
    let f = common::stat_line(p)?
    Ok(d.starts_with("700 " + uid + ":") && f.starts_with("600 " + uid + ":"))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let user = common::param_str(params, "user", "")
    common::valid_user(user)?
    let key = wanted_key(params)?
    let present = common::want_present(params)?
    let dir = ssh_dir(params, user)
    if !present {
        // a deleted user means the key is gone
        if dir.is_err() && common::param_str(params, "home", "") == "" { return Ok(CheckResult::AlreadyConfigured) }
        let p = path::join(dir?, "authorized_keys")
        if !fs::is_file(p) { return Ok(CheckResult::AlreadyConfigured) }
        // an unreadable (non-UTF-8) file is drift; apply reports why
        let text = if let Ok(t) = read_keys(p) { t } else { return Ok(CheckResult::NotConfigured) }
        if rewrite(text, identity(key), "") == text { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let d = dir?
    let p = path::join(d, "authorized_keys")
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    let text = if let Ok(t) = read_keys(p) { t } else { return Ok(CheckResult::NotConfigured) }
    if rewrite(text, identity(key), key) != text { return Ok(CheckResult::NotConfigured) }
    if !attrs_ok(d, p, common::user_uid(user)?)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let user = common::param_str(params, "user", "")
    common::valid_user(user)?
    let key = wanted_key(params)?
    let dir = ssh_dir(params, user)
    if !common::want_present(params)? {
        if dir.is_err() && common::param_str(params, "home", "") == "" { return Ok(ApplyResult::Success) }
        let p = path::join(dir?, "authorized_keys")
        if !fs::is_file(p) { return Ok(ApplyResult::Success) }
        let text = read_keys(p)?
        let next = rewrite(text, identity(key), "")
        if next != text { common::write_atomic(p, next)? }
        return Ok(ApplyResult::Success)
    }
    let d = dir?
    let p = path::join(d, "authorized_keys")
    // the owner is the user, with the group the user's login group, which
    // need not be named after the user
    let ids = common::user_uid(user)? + ":" + common::user_gid(user)?
    if !fs::is_dir(d) {
        fs::mkdir(d)?
        common::run("securing " + d, "chmod 700 -- " + common::q(d))?
    }
    let text = read_keys(p)?
    let next = rewrite(text, identity(key), key)
    if next != text || !fs::is_file(p) { common::write_atomic(p, next)? }
    common::run("securing " + d, "chmod 700 -- " + common::q(d) + " && chmod 600 -- " + common::q(p))?
    common::chown_ids(d, ids)?
    common::chown_ids(p, ids)?
    Ok(ApplyResult::Success)
}
