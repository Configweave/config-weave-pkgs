use value
use fs
use log
use common

// The running hostname, as the kernel holds it.
fn runtime() -> string { "/proc/sys/kernel/hostname" }

// RFC 1123: dot-separated labels of letters, digits and hyphens, 1-63
// characters each, never starting or ending with a hyphen; 64 characters
// at most in all, the kernel's limit.
fn validate(name: string) -> Result[unit, string] {
    if name == "" { return Err("missing 'name' parameter") }
    let bad = Err("invalid hostname '" + name + "' (RFC 1123: letters, digits, hyphens and dots, at most 64 characters)")
    if name.len() > 64 { return bad }
    for label in name.split(".") {
        if label == "" || label.len() > 63 || label.starts_with("-") || label.ends_with("-") { return bad }
        if !label.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-') { return bad }
    }
    Ok(())
}

fn read_trim(p: string) -> string {
    if !fs::is_file(p) { return "" }
    fs::read(p).unwrap_or("").trim()
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    validate(name)?
    if read_trim("/etc/hostname") != name { return Ok(CheckResult::NotConfigured) }
    if read_trim(runtime()) != name { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    validate(name)?
    // hostnamectl sets the static and the running name together, but only
    // works with systemd as PID 1; anywhere else write both directly.
    if common::systemd_running() && common::on_path("hostnamectl") {
        log::info("hostnamectl set-hostname " + name)
        common::run("hostnamectl set-hostname", "hostnamectl set-hostname -- " + common::q(name))?
    }
    if read_trim("/etc/hostname") != name {
        log::info("writing /etc/hostname")
        common::write_atomic("/etc/hostname", name + "\n")?
    }
    if read_trim(runtime()) != name {
        log::info("setting the running hostname")
        fs::write(runtime(), name)?
    }
    Ok(ApplyResult::Success)
}
