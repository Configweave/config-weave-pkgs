use value
use common

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    Ok(name)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let ok = if common::want_present(params)? { common::present(name)? } else { common::absent(name)? }
    if ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

// -S without -y on purpose: syncing the package databases is
// cache_updated's job, not something a package step does behind your back.
// --needed leaves the installed members of a group alone.
fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    if common::want_present(params)? {
        common::run("pacman -S", common::pacman("-S --needed " + common::q(name)))?
        return Ok(ApplyResult::Success)
    }
    common::remove(name)?
    Ok(ApplyResult::Success)
}
