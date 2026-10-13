use value
use shell
use common

fn remote_exists(name: string) -> Result[bool, string] {
    // First column of `flatpak remotes` is the remote name.
    let cmd = "flatpak remotes 2>/dev/null | awk '{{print $1}}' | grep -Fxq " + common::q(name)
    Ok(shell::bash(cmd, Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if remote_exists(name)? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if common::want_present(params)? {
        let url = common::param_str(params, "url", "")
        if url == "" { return Err("missing 'url' parameter") }
        "flatpak remote-add --if-not-exists " + common::q(name) + " " + common::q(url)
    } else {
        "flatpak remote-delete " + common::q(name)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
