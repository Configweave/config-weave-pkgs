use value
use fs
use path
use hash
use http
use common

fn key_path(name: string) -> string { "/etc/apk/keys/" + name + ".rsa.pub" }

fn is_pem_key(text: string) -> bool { text.contains("-----BEGIN PUBLIC KEY-----") }

fn validate(params: Value, present: bool) -> Result[unit, string] {
    common::file_name("name", common::param_str(params, "name", ""))?
    if !present { return Ok(()) }
    let content = common::param_str(params, "content", "")
    let url = common::param_str(params, "url", "")
    let sha = common::param_str(params, "sha256", "").to_lower()
    if (content == "") == (url == "") { return Err("set exactly one of 'content' and 'url'") }
    if url != "" {
        if !url.starts_with("https://") && !url.starts_with("http://") {
            return Err("'url' must be an http:// or https:// URL")
        }
        if sha == "" { return Err("'sha256' is required with 'url': it is what the key on disk is checked against") }
    }
    if sha != "" && (sha.len() != 64 || !sha.chars().all(|c| (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
        return Err("'sha256' must be 64 hex digits")
    }
    if content != "" {
        if !is_pem_key(content) { return Err("'content' is not a PEM public key (no BEGIN PUBLIC KEY line)") }
        if sha != "" && hash::sha256(content) != sha { return Err("'content' does not match 'sha256'") }
    }
    Ok(())
}

// What the key file must hash to: sha256 when set, else content's hash.
fn want_sha(params: Value) -> string {
    let sha = common::param_str(params, "sha256", "").to_lower()
    if sha != "" { sha } else { hash::sha256(common::param_str(params, "content", "")) }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let p = key_path(common::param_str(params, "name", ""))
    if !present {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if let Ok(have) = hash::sha256_file(p) {
        if have == want_sha(params) { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let name = common::param_str(params, "name", "")
    let p = key_path(name)
    if !present {
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    fs::mkdir(path::parent(p))?
    let content = common::param_str(params, "content", "")
    if content != "" {
        fs::write(p, content)?
        return Ok(ApplyResult::Success)
    }
    // Download beside the target and only move it into place once its hash
    // matches, so a bad download never replaces a good key.
    let url = common::param_str(params, "url", "")
    let tmp = path::join(path::parent(p), "." + name + ".rsa.pub.cw-tmp")
    if let Err(e) = http::download(url, tmp, Value::Null) {
        fs::delete(tmp).unwrap_or(())
        return Err("downloading " + url + ": " + e)
    }
    let got = hash::sha256_file(tmp)?
    if got != want_sha(params) {
        fs::delete(tmp).unwrap_or(())
        return Err("the key at " + url + " has sha256 " + got + ", not the expected " + want_sha(params))
    }
    if let Err(e) = fs::move(tmp, p) {
        fs::delete(tmp).unwrap_or(())
        return Err(e)
    }
    Ok(ApplyResult::Success)
}
