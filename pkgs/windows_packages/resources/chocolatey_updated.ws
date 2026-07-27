use value
use fs
use path
use shell
use time

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

// The stamp file's mtime records the last upgrade this resource performed.
fn stamp_path() -> string { "C:/ProgramData/config-weave/chocolatey-updated" }

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
}

fn last_run() -> Result[int, string] {
    let meta = fs::metadata(stamp_path())?
    // `modified` is always present (0 where the platform can't report it),
    // and an epoch mtime simply forces a run.
    if let Some(m) = meta.get("modified") {
        if let Some(ts) = m.as_int() { return Ok(ts) }
    }
    Ok(0)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if !fs::is_file(stamp_path()) { return Ok(CheckResult::NotConfigured) }
    if time::now_millis() / 1000 - last_run()? > max_age_secs(params) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    // Chocolatey queries its sources live and keeps no refreshable index, so
    // — as with flatpak — the useful periodic action is upgrading what is
    // installed, not refreshing metadata that does not exist.
    let out = shell::powershell("choco upgrade all -y", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let stamp = stamp_path()
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, "chocolatey\n")?
    Ok(ApplyResult::Success)
}
