use value
use fs
use path
use time
use common

// The stamp file's mtime records the last update this resource performed.
// :system and :user are separate installations holding separate app sets,
// so each gets its own stamp and window. The :user stamp is not
// uid-qualified: config-weave runs as root, so "the user installation" is
// always root's (/root/.local/share/flatpak).
fn stamp_path(inst: string) -> string { "/var/lib/config-weave/flatpak-updated-" + inst }

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    common::param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
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
    let stamp = stamp_path(common::scope(params)?)
    if !fs::is_file(stamp) { return Ok(CheckResult::NotConfigured) }
    if time::now_millis() / 1000 - last_update(stamp)? > max_age_secs(params) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let inst = common::scope(params)?
    common::run("flatpak update", common::flatpak(inst, "update -y --noninteractive"))?
    let stamp = stamp_path(inst)
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, inst + "\n")?
    Ok(ApplyResult::Success)
}
