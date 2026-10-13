use value
use shell
use common

fn installed(name: string) -> Result[bool, string] {
    // dpkg -s exits 0 even for a removed package whose conffiles remain
    // ("rc" state), so inspect the status field instead.
    let cmd = "test \"$(dpkg-query -W -f='${{db:Status-Status}}' " + common::q(name) + " 2>/dev/null)\" = installed"
    Ok(shell::bash(cmd, Value::Null)?.success)
}

// The installed version string, or "" when not installed.
fn installed_version(name: string) -> Result[string, string] {
    let out = shell::bash("dpkg-query -W -f='${{Version}}' " + common::q(name) + " 2>/dev/null", Value::Null)?
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
        "DEBIAN_FRONTEND=noninteractive apt-get install -y " + common::q(target)
    } else {
        "DEBIAN_FRONTEND=noninteractive apt-get remove -y " + common::q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
