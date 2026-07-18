use value
use fs
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

// versionlock is a plugin for dnf5/dnf/yum; microdnf has no equivalent.
fn dnf_bin() -> Result[string, string] {
    if fs::exists("/usr/bin/dnf5") { return Ok("dnf5") }
    if fs::exists("/usr/bin/dnf") { return Ok("dnf") }
    if fs::exists("/usr/bin/yum") { return Ok("yum") }
    Err("hold requires dnf5, dnf or yum with the versionlock plugin")
}

fn is_held(name: string, bin: string) -> Result[bool, string] {
    Ok(shell::bash(bin + " versionlock list 2>/dev/null | grep -Fq " + q(name), Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let held = is_held(name, dnf_bin()?)?
    if held == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let bin = dnf_bin()?
    let cmd = if want_present(params)? {
        bin + " versionlock add " + q(name)
    } else {
        bin + " versionlock delete " + q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
