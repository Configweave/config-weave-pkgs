use value
use fs
use path
use shell
use time

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

// :system and :user are separate flatpak installations holding separate app
// sets, so each gets its own stamp and its own window — updating one says
// nothing about the other.
fn scope(params: Value) -> Result[string, string] {
    let s = param_str(params, "installation", "system")
    if s == "system" { return Ok(s) }
    if s == "user" { return Ok(s) }
    Err("invalid 'installation' value '" + s + "' (expected :system or :user)")
}

// The stamp file's mtime records the last update this resource performed.
// The :user stamp is not uid-qualified — config-weave runs as root, so
// "the user installation" is always /root/.local/share/flatpak.
fn stamp_path(params: Value) -> Result[string, string] {
    Ok("/var/lib/config-weave/flatpak-updated-" + scope(params)?)
}

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
}

fn last_update(stamp: string) -> Result[int, string] {
    let meta = fs::metadata(stamp)?
    // `modified` is always present (0 where the platform can't report it),
    // and an epoch mtime simply forces an update.
    if let Some(m) = meta.get("modified") {
        if let Some(ts) = m.as_int() { return Ok(ts) }
    }
    Ok(0)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let stamp = stamp_path(params)?
    if !fs::is_file(stamp) { return Ok(CheckResult::NotConfigured) }
    if time::now_millis() / 1000 - last_update(stamp)? > max_age_secs(params) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let inst = scope(params)?
    let out = shell::bash("flatpak update --" + inst + " -y", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let stamp = stamp_path(params)?
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, inst + "\n")?
    Ok(ApplyResult::Success)
}
