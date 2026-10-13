use value
use fs
use path
use shell
use time
use common

// Its own stamp, separate from `cache_updated`'s: the helper refreshes AUR
// metadata that a bare `pacman -Sy` never touches, so one window cannot
// stand in for the other.
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
    // yay and paru refuse to run as root, so the refresh runs as a normal
    // user — the same build user `aur_package` needs.
    let user = common::param_str(params, "user", "")
    if user == "" { return Err("missing 'user' parameter (AUR helpers refuse to run as root)") }
    let h = common::helper(params)?
    let out = shell::bash("sudo -u " + common::q(user) + " " + h + " -Sy --noconfirm", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let stamp = stamp_path()
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, h + "\n")?
    Ok(ApplyResult::Success)
}
