use value
use fs
use path
use shell
use time

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

// The stamp file's mtime records the last refresh this resource performed.
// It is per manager: one machine may run more than one, and a refresh of
// zypper's index says nothing about anyone else's.
fn stamp_path() -> string { "/var/lib/config-weave/zypper-cache-updated" }

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
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
    let out = shell::bash("zypper --non-interactive refresh", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let stamp = stamp_path()
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, "zypper\n")?
    Ok(ApplyResult::Success)
}
