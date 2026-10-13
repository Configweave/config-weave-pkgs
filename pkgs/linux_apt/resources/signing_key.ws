use value
use fs
use path
use shell
use common

// The ASCII-armored key is the source of truth (content-compared); a
// binary .gpg keyring is derived from it when dearmor is requested.
fn asc_path(name: string) -> string { "/etc/apt/keyrings/" + name + ".asc" }
fn gpg_path(name: string) -> string { "/etc/apt/keyrings/" + name + ".gpg" }

fn has_gpg() -> bool {
    if let Ok(out) = shell::bash("command -v gpg", Value::Null) { out.success } else { false }
}

// A file that cannot be read as text holds something other than content.
fn holds(p: string, content: string) -> bool {
    if !fs::is_file(p) { return false }
    if let Ok(text) = fs::read(p) { text == content } else { false }
}

// Dearmoring is a pure decode, so the keyring is current exactly when it
// is byte for byte what gpg --dearmor makes of the .asc now.
fn keyring_current(name: string) -> Result[bool, string] {
    if !fs::is_file(gpg_path(name)) { return Ok(false) }
    let cmd = "gpg --batch --dearmor < " + common::q(asc_path(name)) + " | cmp -s - " + common::q(gpg_path(name))
    Ok(shell::bash(cmd, Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::file_name("name", name)?
    if !common::want_present(params)? {
        if fs::is_file(asc_path(name)) || fs::is_file(gpg_path(name)) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    if !holds(asc_path(name), content) { return Ok(CheckResult::NotConfigured) }
    if common::param_bool(params, "dearmor", false) {
        // gpg may yet be installed by an earlier step; apply says why if not
        if !has_gpg() { return Ok(CheckResult::NotConfigured) }
        if !keyring_current(name)? { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    common::file_name("name", name)?
    if !common::want_present(params)? {
        if fs::is_file(asc_path(name)) { fs::delete(asc_path(name))? }
        if fs::is_file(gpg_path(name)) { fs::delete(gpg_path(name))? }
        return Ok(ApplyResult::Success)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    let dearmor = common::param_bool(params, "dearmor", false)
    if dearmor && !has_gpg() {
        return Err("dearmor = true needs gpg, which is not installed; install the gpg package first, or set dearmor = false and point signed-by at the .asc")
    }
    let asc = asc_path(name)
    fs::mkdir(path::parent(asc))?
    fs::write(asc, content)?
    if dearmor {
        common::run("gpg --dearmor " + asc, "gpg --batch --yes --dearmor -o " + common::q(gpg_path(name)) + " " + common::q(asc))?
    }
    Ok(ApplyResult::Success)
}
