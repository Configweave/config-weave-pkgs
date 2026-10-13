use value
use shell
use common

fn installed(name: string) -> Result[bool, string] {
    // pacman sees AUR-installed packages too, and needs no build user.
    Ok(shell::bash("pacman -Q " + common::q(name) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if installed(name)? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    // AUR builds cannot run as root, so the helper runs as a normal user.
    let user = common::param_str(params, "user", "")
    if user == "" { return Err("missing 'user' parameter (AUR builds cannot run as root)") }
    let h = common::helper(params)?
    let cmd = if common::want_present(params)? {
        "sudo -u " + common::q(user) + " " + h + " -S --noconfirm " + common::q(name)
    } else {
        "sudo -u " + common::q(user) + " " + h + " -R --noconfirm " + common::q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
