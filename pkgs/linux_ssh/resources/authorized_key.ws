use value
use common
use fs
use path
use shell

fn home_for(user: string, override_home: string) -> Result[string, string] {
    if override_home != "" { return Ok(override_home) }
    let out = shell::bash("getent passwd " + common::q(user) + " | cut -d: -f6", Value::Null)?
    if !out.success || out.stdout.trim() == "" { return Err("cannot determine home for user " + user) }
    Ok(out.stdout.trim())
}

fn key_path(user: string, home: string) -> string { home + "/.ssh/authorized_keys" }

fn contains_key(text: string, key: string) -> bool {
    for line in text.split("\n") { if line.trim() == key.trim() { return true } }
    false
}

// Remove exactly the trimmed-equal key lines, preserving everything else
// (including blank lines) and the trailing newline.
fn without_key(text: string, key: string) -> string {
    let had_nl = text.ends_with("\n")
    let kept = []
    for line in text.split("\n") {
        if line.trim() != key.trim() { kept.push(line) }
    }
    // splitting "a\n" yields ["a", ""] — drop that artifact so join doesn't
    // double the trailing newline
    if had_nl && kept.len() > 0 && kept.get(kept.len() - 1).unwrap_or("x") == "" {
        let dropped = kept.remove(kept.len() - 1)
    }
    let body = kept.join("\n")
    if body == "" { "" } else { body + "\n" }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let user = common::param_str(params, "user", "")
    let key = common::param_str(params, "key", "")
    if user == "" { return Err("missing 'user' parameter") }
    if key == "" { return Err("missing 'key' parameter") }
    if !common::want_present(params)? {
        // a deleted user (or missing key file) means the key is gone
        let home = home_for(user, common::param_str(params, "home", ""))
        if home.is_err() { return Ok(CheckResult::AlreadyConfigured) }
        let p = key_path(user, home.unwrap_or(""))
        if !fs::is_file(p) { return Ok(CheckResult::AlreadyConfigured) }
        if contains_key(fs::read(p)?, key) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let p = key_path(user, home_for(user, common::param_str(params, "home", ""))?)
    if fs::is_file(p) && contains_key(fs::read(p)?, key) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let user = common::param_str(params, "user", "")
    let key = common::param_str(params, "key", "")
    if !common::want_present(params)? {
        let home = home_for(user, common::param_str(params, "home", ""))
        if home.is_err() { return Ok(ApplyResult::Success) }
        let p = key_path(user, home.unwrap_or(""))
        if !fs::is_file(p) { return Ok(ApplyResult::Success) }
        fs::write(p, without_key(fs::read(p)?, key))?
        return Ok(ApplyResult::Success)
    }
    let home = home_for(user, common::param_str(params, "home", ""))?
    let p = key_path(user, home)
    fs::mkdir(path::parent(p))?
    let text = if fs::exists(p) { fs::read(p)? } else { "" }
    if !contains_key(text, key) {
        let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
        fs::write(p, text + sep + key.trim() + "\n")?
    }
    let out = shell::bash("chmod 700 " + common::q(home + "/.ssh") + " && chmod 600 " + common::q(p) + " && chown -R " + common::q(user) + ":" + common::q(user) + " " + common::q(home + "/.ssh"), Value::Null)?
    if !out.success { return Err("securing " + home + "/.ssh failed: " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

