use value
use fs
use path
use shell
use time
use common

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    common::param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
}

fn last_refresh() -> Result[int, string] {
    let meta = fs::metadata(common::stamp_path())?
    // `modified` is always present (0 where the platform can't report it),
    // and an epoch mtime simply forces a refresh.
    if let Some(m) = meta.get("modified") {
        if let Some(ts) = m.as_int() { return Ok(ts) }
    }
    Ok(0)
}

// A repository line or key added, changed or removed after the last refresh
// means the index is out of date whatever its age: a deleted file bumps its
// directory. Missing paths are skipped.
fn sources_changed() -> Result[bool, string] {
    let out = shell::bash("find " + common::sources() + " -newer " + common::q(common::stamp_path()) + " -print 2>/dev/null | head -n 1", Value::Null)?
    Ok(out.stdout.trim() != "")
}

fn check(params: Value) -> Result[CheckResult, string] {
    if !fs::is_file(common::stamp_path()) { return Ok(CheckResult::NotConfigured) }
    if time::now_millis() / 1000 - last_refresh()? > max_age_secs(params) {
        return Ok(CheckResult::NotConfigured)
    }
    if sources_changed()? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::output("apk update", common::apk("update"))?
    let stamp = common::stamp_path()
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, "apk\n")?
    Ok(ApplyResult::Success)
}
