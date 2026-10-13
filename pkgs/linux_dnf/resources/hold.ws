use value
use shell
use common

fn is_held(name: string, bin: string) -> Result[bool, string] {
    Ok(shell::bash(bin + " versionlock list 2>/dev/null | grep -Fq " + common::q(name), Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let held = is_held(name, common::lock_bin()?)?
    if held == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let bin = common::lock_bin()?
    let cmd = if common::want_present(params)? {
        bin + " versionlock add " + common::q(name)
    } else {
        bin + " versionlock delete " + common::q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
