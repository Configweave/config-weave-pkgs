use value
use shell
use common

fn installed(id: string) -> Result[bool, string] {
    Ok(shell::bash("flatpak info " + common::q(id) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let id = common::param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    if installed(id)? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let id = common::param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    let cmd = if common::want_present(params)? {
        let remote = common::param_str(params, "remote", "flathub")
        "flatpak install -y " + common::q(remote) + " " + common::q(id)
    } else {
        "flatpak uninstall -y " + common::q(id)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
