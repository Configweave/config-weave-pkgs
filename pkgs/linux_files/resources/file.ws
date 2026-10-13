use value
use fs
use path
use http
use hash
use log
use common

// url mode and content mode are mutually exclusive; sha256 only makes sense
// alongside a url.
fn source_url(params: Value) -> Result[string, string] {
    let url = common::param_str(params, "url", "")
    if url != "" && common::param_str(params, "content", "") != "" {
        return Err("'url' and 'content' are mutually exclusive")
    }
    if url == "" && common::param_str(params, "sha256", "") != "" {
        return Err("'sha256' requires 'url'")
    }
    Ok(url)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    let url = source_url(params)?
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if url != "" {
        let want = common::param_str(params, "sha256", "")
        if want != "" && hash::sha256_file(p)? != want { return Ok(CheckResult::NotConfigured) }
    } else {
        if fs::read(p)? != common::param_str(params, "content", "") { return Ok(CheckResult::NotConfigured) }
    }
    if !common::attrs_ok(p, a)? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    let url = source_url(params)?
    if !common::want_present(params)? {
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        if fs::is_dir(p) { return Err("path is a directory; use linux_files.directory with ensure = :absent") }
        log::info("deleting " + p)
        fs::delete(p)?
        return Ok(ApplyResult::Success)
    }
    if url != "" {
        let want = common::param_str(params, "sha256", "")
        // Only fetch when the file is missing or fails its digest — keeps a
        // metadata-only fix (mode/owner) from re-downloading.
        let need = !fs::is_file(p) || (want != "" && hash::sha256_file(p)? != want)
        if need {
            log::info("downloading " + url + " -> " + p)
            fs::mkdir(path::parent(p))?
            http::download(url, p, Value::Null)?
            if want != "" && hash::sha256_file(p)? != want { return Err("downloaded file sha256 mismatch") }
        }
    } else {
        log::info("writing " + p)
        fs::mkdir(path::parent(p))?
        fs::write(p, common::param_str(params, "content", ""))?
    }
    common::apply_attrs(p, a)?
    Ok(ApplyResult::Success)
}
