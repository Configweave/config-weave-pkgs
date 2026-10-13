use value
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    if common::held(name)? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    let verb = if common::want_present(params)? { "hold" } else { "unhold" }
    common::run("apt-mark " + verb + " " + name, "apt-mark " + verb + " " + common::q(name))?
    Ok(ApplyResult::Success)
}
