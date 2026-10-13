use value
use shell
use common

fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("rpm -q " + common::q(name) + " >/dev/null 2>&1", Value::Null)?.success)
}

// The installed version string, or "" when not installed.
fn installed_version(name: string) -> Result[string, string] {
    let out = shell::bash("rpm -q --qf '%{{VERSION}}' " + common::q(name) + " 2>/dev/null", Value::Null)?
    if !out.success { return Ok("") }
    Ok(out.stdout.trim())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    let version = common::param_str(params, "version", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !common::want_present(params)? {
        // existence probe only: any installed version means work to do
        if installed(name)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if version == "" {
        if installed(name)? { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if installed_version(name)? == version { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    let version = common::param_str(params, "version", "")
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if common::want_present(params)? {
        let target = if version != "" { name + "=" + version } else { name }
        "zypper --non-interactive install " + common::q(target)
    } else {
        "zypper --non-interactive remove " + common::q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
