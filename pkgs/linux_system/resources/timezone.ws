use value
use fs
use shell
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if fs::is_file("/etc/timezone") && fs::read("/etc/timezone")?.trim() == name { return Ok(CheckResult::AlreadyConfigured) }
    if fs::read_link("/etc/localtime").unwrap_or("").ends_with("/zoneinfo/" + name) { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if fs::exists("/usr/bin/timedatectl") {
        let out = shell::bash("timedatectl set-timezone " + common::q(name), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    } else {
        fs::write("/etc/timezone", name + "\n")?
        if fs::exists("/usr/share/zoneinfo/" + name) {
            if fs::exists("/etc/localtime") { fs::delete("/etc/localtime")? }
            fs::symlink("/usr/share/zoneinfo/" + name, "/etc/localtime")?
        }
    }
    Ok(ApplyResult::Success)
}

