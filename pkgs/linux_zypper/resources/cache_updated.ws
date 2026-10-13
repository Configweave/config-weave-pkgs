use value
use fs
use path
use shell
use time
use common

// The stamp file's mtime records the last refresh this resource performed.
// Each package manager package keeps its own: zypper's index says nothing
// about any other manager's.
fn stamp_path() -> string { "/var/lib/config-weave/zypper-cache-updated" }

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

// Repository definitions. A file added, changed or removed here after the
// last refresh means the cache is out of date whatever its age.
fn sources() -> string { "/etc/zypp/repos.d" }

fn sources_changed() -> Result[bool, string] {
    let out = shell::bash("find " + sources() + " -newer " + common::q(stamp_path()) + " -print 2>/dev/null | head -n 1", Value::Null)?
    Ok(out.stdout.trim() != "")
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
    // A repository that failed to refresh (exit 106) leaves the cache stale,
    // so it is an error here rather than the success it is for install.
    let global = if common::param_bool(params, "gpg_auto_import_keys", false) { "--gpg-auto-import-keys " } else { "" }
    common::zypper("zypper refresh", global + "refresh", false)?
    let stamp = stamp_path()
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, "zypper\n")?
    Ok(ApplyResult::Success)
}
