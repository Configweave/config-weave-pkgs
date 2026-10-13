use value
use fs
use path
use shell
use time
use common

// The stamp file's mtime records the last refresh this resource performed.
// Each package manager package keeps its own: apt's index says nothing
// about any other manager's.
fn stamp_path() -> string { "/var/lib/config-weave/apt-cache-updated" }

// Everything that changes what apt-get update fetches. A file added,
// changed or removed under these after the last refresh means the index
// is out of date whatever its age: a deleted file bumps its directory.
fn sources() -> string { "/etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/keyrings /etc/apt/trusted.gpg.d" }

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

// find compares full-resolution mtimes, so a source written in the same
// second as the stamp still sorts correctly. Missing paths are skipped.
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
    common::run("apt-get update", common::apt_get("update"))?
    let stamp = stamp_path()
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, "apt\n")?
    Ok(ApplyResult::Success)
}
