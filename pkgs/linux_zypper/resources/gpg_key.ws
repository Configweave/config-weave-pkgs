use value
use fs
use path
use http
use shell
use common

fn key_path(name: string) -> string { "/etc/pki/rpm-gpg/" + name + ".asc" }

fn validate(params: Value, present: bool) -> Result[unit, string] {
    common::file_name("name", common::param_str(params, "name", ""))?
    if !present { return Ok(()) }
    let content = common::param_str(params, "content", "")
    let url = common::param_str(params, "url", "")
    if (content == "") == (url == "") { return Err("set exactly one of 'content' and 'url'") }
    if url != "" && !url.starts_with("https://") && !url.starts_with("http://") {
        return Err("'url' must be an http:// or https:// URL")
    }
    Ok(())
}

fn read_text(p: string) -> string {
    if !fs::is_file(p) { return "" }
    fs::read(p).unwrap_or("")
}

fn all_imported(ids: List[string]) -> Result[bool, string] {
    for id in ids {
        if !common::key_imported(id)? { return Ok(false) }
    }
    Ok(true)
}

fn any_imported(ids: List[string]) -> Result[bool, string] {
    for id in ids {
        if common::key_imported(id)? { return Ok(true) }
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let p = key_path(common::param_str(params, "name", ""))
    let content = common::param_str(params, "content", "")
    if !present {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        if content != "" && any_imported(common::key_ids(content)?)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let have = read_text(p)
    // A url is fetched once: its stored copy stands for it from then on.
    if have == "" || (content != "" && have != content) { return Ok(CheckResult::NotConfigured) }
    // the file alone proves nothing: the key may have been removed from the
    // rpm database since
    if let Ok(ids) = common::key_ids(have) {
        if all_imported(ids)? { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let name = common::param_str(params, "name", "")
    let p = key_path(name)
    let content = common::param_str(params, "content", "")
    if !present {
        // the keys to erase: those in content, else those in the file
        let text = if content != "" { content } else { read_text(p) }
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
    // Write a temp file beside the target, import it, and only then move it
    // into place, so a key rpm rejects never leaves a file that reads as done.
    fs::mkdir(path::parent(p))?
    let tmp = path::join(path::parent(p), "." + name + ".asc.cw-tmp")
    let url = common::param_str(params, "url", "")
    if url != "" && !fs::is_file(p) {
        if let Err(e) = http::download(url, tmp, Value::Null) {
            fs::delete(tmp).unwrap_or(())
            return Err("downloading " + url + ": " + e)
        }
    } else if url != "" {
        // re-import the stored copy of a key fetched before
        fs::copy(p, tmp)?
    } else {
        fs::write(tmp, content)?
    }
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
