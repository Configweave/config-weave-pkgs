use value
use shell
use common

fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("apk info -e " + common::q(name) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if installed(name)? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if common::want_present(params)? { "apk add " + common::q(name) } else { "apk del " + common::q(name) }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
