use value
use shell
use common

fn is_held(name: string) -> Result[bool, string] {
    Ok(shell::bash("apt-mark showhold | grep -Fxq " + common::q(name), Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if is_held(name)? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if common::want_present(params)? { "apt-mark hold " + common::q(name) } else { "apt-mark unhold " + common::q(name) }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
