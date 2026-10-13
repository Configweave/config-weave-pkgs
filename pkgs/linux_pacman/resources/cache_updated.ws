use value
use fs
use path
use shell
use time
use common

// The stamp file's mtime records the last refresh this resource performed.
// It is per manager: one machine may run more than one, and a refresh of
// pacman's databases says nothing about anyone else's.
fn stamp_path() -> string { "/var/lib/config-weave/pacman-cache-updated" }

// What decides which databases pacman -Sy fetches and from where. A file
// added, changed or removed under these after the last refresh means the
// databases are out of date whatever their age.
fn sources() -> string { "/etc/pacman.conf /etc/pacman.d" }

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

// The keyring under /etc/pacman.d/gnupg changes on every pacman run that
// verifies a signature (trustdb, random seed), so it is left out.
fn sources_changed() -> Result[bool, string] {
    let cmd = "find " + sources() + " -path /etc/pacman.d/gnupg -prune -o -newer " + common::q(stamp_path()) + " -print 2>/dev/null | head -n 1"
    Ok(shell::bash(cmd, Value::Null)?.stdout.trim() != "")
}

fn check(params: Value) -> Result[CheckResult, string] {
    if !fs::is_file(stamp_path()) { return Ok(CheckResult::NotConfigured) }
    if time::now_millis() / 1000 - last_refresh()? > max_age_secs(params) {
        return Ok(CheckResult::NotConfigured)
    }
    if sources_changed()? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::output("pacman -Sy", common::pacman("-Sy"))?
    let stamp = stamp_path()
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, "pacman\n")?
    Ok(ApplyResult::Success)
}
