use value
use fs
use path
use shell
use common

fn key_path(name: string) -> string { "/etc/pki/rpm-gpg/" + name + ".asc" }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = key_path(name)
    if !common::want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    if fs::is_file(p) && fs::read(p)? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = key_path(name)
    if !common::want_present(params)? {
        // removes the key file only; a key already imported into the rpm
        // database stays there (rpm -e gpg-pubkey-... would need the key id)
        if fs::is_file(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    fs::mkdir(path::parent(p))?
    fs::write(p, content)?
    // rpm --import is idempotent: re-importing the same key is a no-op.
    let out = shell::bash("rpm --import " + common::q(p), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
