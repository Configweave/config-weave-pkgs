use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn installed(name: string) -> Result[bool, string] {
    // dpkg -s exits 0 even for a removed package whose conffiles remain
    // ("rc" state), so inspect the status field instead.
    let cmd = "test \"$(dpkg-query -W -f='${{db:Status-Status}}' " + q(name) + " 2>/dev/null)\" = installed"
    Ok(shell::bash(cmd, Value::Null)?.success)
}

// The installed version string, or "" when not installed.
fn installed_version(name: string) -> Result[string, string] {
    let out = shell::bash("dpkg-query -W -f='${{Version}}' " + q(name) + " 2>/dev/null", Value::Null)?
    if !out.success { return Ok("") }
    Ok(out.stdout.trim())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
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
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if want_present(params)? {
        let target = if version != "" { name + "=" + version } else { name }
        "DEBIAN_FRONTEND=noninteractive apt-get install -y " + q(target)
    } else {
        "DEBIAN_FRONTEND=noninteractive apt-get remove -y " + q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
