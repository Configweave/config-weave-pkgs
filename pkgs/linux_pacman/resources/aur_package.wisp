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

// Resolve the AUR helper: an explicit yay/paru is taken as-is; "auto"
// looks for yay then paru in /usr/bin and /bin.
fn helper(params: Value) -> Result[string, string] {
    let h = param_str(params, "helper", "auto")
    if h == "yay" || h == "paru" { return Ok(h) }
    if h != "auto" { return Err("invalid 'helper' value '" + h + "' (expected auto, yay or paru)") }
    if fs::exists("/usr/bin/yay") || fs::exists("/bin/yay") { return Ok("yay") }
    if fs::exists("/usr/bin/paru") || fs::exists("/bin/paru") { return Ok("paru") }
    Err("no AUR helper found (looked for yay and paru in /usr/bin and /bin)")
}

fn installed(name: string) -> Result[bool, string] {
    // pacman sees AUR-installed packages too, and needs no build user.
    Ok(shell::bash("pacman -Q " + q(name) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if installed(name)? == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    // AUR builds cannot run as root, so the helper runs as a normal user.
    let user = param_str(params, "user", "")
    if user == "" { return Err("missing 'user' parameter (AUR builds cannot run as root)") }
    let h = helper(params)?
    let cmd = if want_present(params)? {
        "sudo -u " + q(user) + " " + h + " -S --noconfirm " + q(name)
    } else {
        "sudo -u " + q(user) + " " + h + " -R --noconfirm " + q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
