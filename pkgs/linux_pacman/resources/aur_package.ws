use value
use shell
use common

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    Ok(name)
}

// pacman sees AUR-installed packages too, so checking needs no build user.
fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let ok = if common::want_present(params)? { common::satisfied(name)? } else { common::absent(name)? }
    if ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    if !common::want_present(params)? {
        // An AUR package is an ordinary package once installed: pacman
        // removes it as root, with no build user or helper.
        common::remove(name)?
        return Ok(ApplyResult::Success)
    }
    // AUR builds cannot run as root, so the helper runs as a normal user.
    let user = common::param_str(params, "user", "")
    if user == "" { return Err("missing 'user' parameter (AUR builds cannot run as root)") }
    common::user_name(user)?
    let h = common::helper(params, user)?
    let out = shell::bash(common::as_user(user, h + " -S --noconfirm --needed " + common::q(name)), Value::Null)?
    if !out.success { return Err(common::cmd_err(h + " -S", out)) }
    Ok(ApplyResult::Success)
}
