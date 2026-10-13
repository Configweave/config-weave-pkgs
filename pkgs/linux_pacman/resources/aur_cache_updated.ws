use value
use fs
use path
use shell
use time
use common

// Its own stamp, separate from cache_updated's, so a playbook that syncs
// through the helper keeps its own window.
fn stamp_path() -> string { "/var/lib/config-weave/pacman-aur-cache-updated" }

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    common::param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
}

fn last_refresh() -> Result[int, string] {
    let meta = fs::metadata(stamp_path())?
    // `modified` is always present (0 where the platform can't report it),
    // and an epoch mtime simply forces a refresh.
    if let Some(m) = meta.get("modified") {
        if let Some(ts) = m.as_int() { return Ok(ts) }
    }
    Ok(0)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if !fs::is_file(stamp_path()) { return Ok(CheckResult::NotConfigured) }
    if time::now_millis() / 1000 - last_refresh()? > max_age_secs(params) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    // yay and paru refuse to run as root, so the sync runs as a normal user
    // — the same build user aur_package needs. `-Sy` through either helper
    // syncs the pacman databases (the helper calls sudo pacman); AUR
    // metadata has no local database to refresh, since both helpers query
    // the AUR live on every search and install.
    let user = common::param_str(params, "user", "")
    if user == "" { return Err("missing 'user' parameter (AUR helpers refuse to run as root)") }
    common::user_name(user)?
    let h = common::helper(params, user)?
    let out = shell::bash(common::as_user(user, h + " -Sy --noconfirm"), Value::Null)?
    if !out.success { return Err(common::cmd_err(h + " -Sy", out)) }
    let stamp = stamp_path()
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, h + "\n")?
    Ok(ApplyResult::Success)
}
