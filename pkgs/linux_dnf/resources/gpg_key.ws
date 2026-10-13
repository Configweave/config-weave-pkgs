use value
use fs
use path
use shell
use common

fn key_path(name: string) -> string { "/etc/pki/rpm-gpg/" + name + ".asc" }

// A file that cannot be read as text holds something other than content.
fn holds(p: string, content: string) -> bool {
    if !fs::is_file(p) { return false }
    if let Ok(text) = fs::read(p) { text == content } else { false }
}

fn any_imported(ids: List[string]) -> Result[bool, string] {
    for id in ids {
        if common::key_imported(id)? { return Ok(true) }
    }
    Ok(false)
}

fn all_imported(ids: List[string]) -> Result[bool, string] {
    for id in ids {
        if !common::key_imported(id)? { return Ok(false) }
    }
    Ok(true)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::file_name("name", name)?
    let p = key_path(name)
    let content = common::param_str(params, "content", "")
    if !common::want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        if content != "" && any_imported(common::key_ids(content)?)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if content == "" { return Err("missing 'content' parameter") }
    if !holds(p, content) { return Ok(CheckResult::NotConfigured) }
    // the file alone proves nothing: the import may have failed, or the key
    // been removed from the rpm database since
    if !all_imported(common::key_ids(content)?)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    common::file_name("name", name)?
    let p = key_path(name)
    let content = common::param_str(params, "content", "")
    if !common::want_present(params)? {
        // the keys to erase: those in content, else those in the file
        let text = if content != "" { content } else if fs::is_file(p) { fs::read(p).unwrap_or("") } else { "" }
        if text != "" {
            if let Ok(ids) = common::key_ids(text) {
                for id in ids { common::delete_key(id)? }
            } else if content != "" {
                return Err("'content' is not a valid OpenPGP public key")
            }
        }
        if fs::is_file(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    if content == "" { return Err("missing 'content' parameter") }
    // Import from a temp file beside the target and only then move it into
    // place, so a key rpm rejects never leaves a file that reads as done.
    fs::mkdir(path::parent(p))?
    let tmp = path::join(path::parent(p), "." + name + ".asc.cw-tmp")
    fs::write(tmp, content)?
    let out = shell::bash("rpm --import " + common::q(tmp), Value::Null)?
    if !out.success {
        fs::delete(tmp).unwrap_or(())
        return Err(common::cmd_err("rpm --import", out))
    }
    if let Err(e) = fs::move(tmp, p) {
        fs::delete(tmp).unwrap_or(())
        return Err(e)
    }
    Ok(ApplyResult::Success)
}
