use value
use fs
use path
use shell
use time
use common

// The stamp file's mtime records the last refresh this resource performed.
// One per front-end: dnf5 and dnf4 (or yum) keep separate caches, so a
// refresh by one says nothing about the other's.
fn stamp_path(bin: string) -> string { "/var/lib/config-weave/dnf-cache-updated-" + bin }

// Repository definitions. A file added, changed or removed here after the
// last refresh means the cache is out of date whatever its age.
fn sources() -> string { "/etc/yum.repos.d /etc/distro.repos.d" }

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    common::param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
}

fn last_refresh(stamp: string) -> Result[int, string] {
    let meta = fs::metadata(stamp)?
    // `modified` is always present (0 where the platform can't report it),
    // and an epoch mtime simply forces a refresh.
    if let Some(m) = meta.get("modified") {
        if let Some(ts) = m.as_int() { return Ok(ts) }
    }
    Ok(0)
}

fn sources_changed(stamp: string) -> Result[bool, string] {
    let out = shell::bash("find " + sources() + " -newer " + common::q(stamp) + " -print 2>/dev/null | head -n 1", Value::Null)?
    Ok(out.stdout.trim() != "")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let stamp = stamp_path(common::dnf_bin()?)
    if !fs::is_file(stamp) { return Ok(CheckResult::NotConfigured) }
    if time::now_millis() / 1000 - last_refresh(stamp)? > max_age_secs(params) {
        return Ok(CheckResult::NotConfigured)
    }
    if sources_changed(stamp)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let bin = common::dnf_bin()?
    // makecache alone is a no-op while the metadata is younger than the
    // repository's metadata_expire, so the refresh is forced. yum has no
    // --refresh; expiring its cache first does the same.
    let cmd = if bin == "yum" {
        "yum clean expire-cache && yum makecache -y"
    } else if bin == "microdnf" {
        // microdnf has no -y for makecache
        "microdnf makecache --refresh"
    } else {
        bin + " makecache --refresh -y"
    }
    common::run(bin + " makecache", cmd)?
    let stamp = stamp_path(bin)
    fs::mkdir(path::parent(stamp))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, bin + "\n")?
    Ok(ApplyResult::Success)
}
