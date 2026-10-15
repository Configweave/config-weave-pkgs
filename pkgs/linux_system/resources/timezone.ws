use value
use fs
use hash
use log
use common

fn zone_file(name: string) -> string { "/usr/share/zoneinfo/" + name }

fn validate(name: string) -> Result[unit, string] {
    if name == "" { return Err("missing 'name' parameter") }
    common::one_line("name", name)?
    if common::has_space(name) || name.starts_with("/") || name.starts_with("-") {
        return Err("invalid timezone name '" + name + "'")
    }
    for seg in name.split("/") {
        if seg == "" || seg == "." || seg == ".." { return Err("invalid timezone name '" + name + "'") }
    }
    Ok(())
}

// /etc/localtime is what libc reads. It is normally a symlink into
// zoneinfo; some images copy the zone file instead, so a regular file
// matches when its bytes are the zone's.
fn localtime_is(name: string) -> Result[bool, string] {
    if let Ok(target) = fs::read_link("/etc/localtime") {
        return Ok(target.ends_with("/zoneinfo/" + name) || target == "zoneinfo/" + name)
    }
    if !fs::is_file("/etc/localtime") || !fs::is_file(zone_file(name)) { return Ok(false) }
    Ok(hash::sha256_file("/etc/localtime")? == hash::sha256_file(zone_file(name))?)
}

// /etc/timezone is Debian's copy of the name; only compared where it exists.
fn timezone_file_ok(name: string) -> bool {
    if !fs::is_file("/etc/timezone") { return true }
    if let Ok(text) = fs::read("/etc/timezone") { text.trim() == name } else { false }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    validate(name)?
    if localtime_is(name)? && timezone_file_ok(name) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    validate(name)?
    if !fs::is_file(zone_file(name)) {
        return Err("unknown timezone '" + name + "': " + zone_file(name) + " does not exist (is tzdata installed?)")
    }
    // timedatectl needs systemd as PID 1; anywhere else (containers,
    // OpenRC, runit) it fails, so write the files directly.
    if common::systemd_running() && common::on_path("timedatectl") {
        log::info("timedatectl set-timezone " + name)
        common::run("timedatectl set-timezone", "timedatectl set-timezone -- " + common::q(name))?
    } else {
        log::info("linking /etc/localtime to " + zone_file(name))
        // lexists, not exists: exists follows the link, so a dangling
        // /etc/localtime would survive and fs::symlink would fail
        if fs::lexists("/etc/localtime") { fs::delete("/etc/localtime")? }
        fs::symlink(zone_file(name), "/etc/localtime")?
    }
    if fs::is_file("/etc/timezone") && !timezone_file_ok(name) {
        fs::write("/etc/timezone", name + "\n")?
    }
    Ok(ApplyResult::Success)
}
