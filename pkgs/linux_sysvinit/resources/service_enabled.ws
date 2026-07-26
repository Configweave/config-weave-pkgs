use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn has_update_rcd() -> bool { fs::exists("/usr/sbin/update-rc.d") || fs::exists("/sbin/update-rc.d") }
fn has_chkconfig() -> bool { fs::exists("/sbin/chkconfig") || fs::exists("/usr/sbin/chkconfig") }

// Enabled means a start symlink exists in any runlevel directory.
fn start_links(name: string) -> Result[bool, string] {
    let matches = fs::glob("/etc/rc?.d/S??" + name)?
    Ok(!matches.is_empty())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let enabled = start_links(name)?
    if enabled == param_bool(params, "enabled", true) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let want = param_bool(params, "enabled", true)
    if has_update_rcd() {
        let cmd = if want { "update-rc.d " + q(name) + " defaults" } else { "update-rc.d -f " + q(name) + " remove" }
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    if has_chkconfig() {
        let cmd = "chkconfig " + q(name) + (if want { " on" } else { " off" })
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    Err("neither update-rc.d nor chkconfig found")
}
