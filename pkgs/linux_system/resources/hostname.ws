use value
use fs
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !fs::is_file("/etc/hostname") { return Ok(CheckResult::NotConfigured) }
    if fs::read("/etc/hostname")?.trim() != name { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    fs::write("/etc/hostname", name + "\n")?
    Ok(ApplyResult::Success)
}
