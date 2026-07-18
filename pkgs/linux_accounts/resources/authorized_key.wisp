use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn home_for(user: string, override_home: string) -> Result[string, string] {
    if override_home != "" { return Ok(override_home) }
    let out = shell::bash("getent passwd " + q(user) + " | cut -d: -f6", Value::Null)?
    if !out.success || out.stdout.trim() == "" { return Err("cannot determine home for user " + user) }
    Ok(out.stdout.trim())
}

fn key_path(user: string, home: string) -> string { home + "/.ssh/authorized_keys" }

fn contains_key(text: string, key: string) -> bool {
    for line in text.split("\n") { if line.trim() == key.trim() { return true } }
    false
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
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
    let user = param_str(params, "user", "")
    let key = param_str(params, "key", "")
    if user == "" { return Err("missing 'user' parameter") }
    if key == "" { return Err("missing 'key' parameter") }
    if !want_present(params)? {
        // a deleted user (or missing key file) means the key is gone
        let home = home_for(user, param_str(params, "home", ""))
        if home.is_err() { return Ok(CheckResult::AlreadyConfigured) }
        let p = key_path(user, home.unwrap_or(""))
        if !fs::is_file(p) { return Ok(CheckResult::AlreadyConfigured) }
        if contains_key(fs::read(p)?, key) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let p = key_path(user, home_for(user, param_str(params, "home", ""))?)
    if fs::is_file(p) && contains_key(fs::read(p)?, key) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let user = param_str(params, "user", "")
    let key = param_str(params, "key", "")
    if !want_present(params)? {
        let home = home_for(user, param_str(params, "home", ""))
        if home.is_err() { return Ok(ApplyResult::Success) }
        let p = key_path(user, home.unwrap_or(""))
        if !fs::is_file(p) { return Ok(ApplyResult::Success) }
        fs::write(p, without_key(fs::read(p)?, key))?
        return Ok(ApplyResult::Success)
    }
    let home = home_for(user, param_str(params, "home", ""))?
    let p = key_path(user, home)
    fs::mkdir(path::parent(p))?
    let text = if fs::exists(p) { fs::read(p)? } else { "" }
    if !contains_key(text, key) {
        let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
        fs::write(p, text + sep + key.trim() + "\n")?
    }
    let out = shell::bash("chmod 700 " + q(home + "/.ssh") + " && chmod 600 " + q(p) + " && chown -R " + q(user) + ":" + q(user) + " " + q(home + "/.ssh"), Value::Null)?
    if !out.success { return Err("securing " + home + "/.ssh failed: " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

