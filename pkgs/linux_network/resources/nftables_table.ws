use value
use common
use fs
use shell

fn table_exists(family: string, name: string) -> Result[bool, string] {
    let out = shell::bash("nft list table " + common::q(family) + " " + common::q(name) + " 2>/dev/null", Value::Null)?
    Ok(out.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    common::require_nft()?
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let exists = table_exists(common::param_str(params, "family", "inet"), name)?
    if exists == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_nft()?
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let family = common::param_str(params, "family", "inet")
    let verb = if common::want_present(params)? { "add" } else { "delete" }
    let out = shell::bash("nft " + verb + " table " + common::q(family) + " " + common::q(name), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
