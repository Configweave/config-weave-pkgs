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

// The expected digest, lower-cased; "" when none was given.
fn want_sha(params: Value) -> Result[string, string] {
    let want = common::param_str(params, "sha256", "").trim().to_lower()
    if want == "" { return Ok("") }
    if want.len() != 64 || !want.chars().all(|c| (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
        return Err("invalid 'sha256' (expected 64 hex digits)")
    }
    Ok(want)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    let url = source_url(params)?
    let want = want_sha(params)?
    if !common::want_present(params)? {
        if common::lexists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if url != "" {
        if want != "" && hash::sha256_file(p)? != want { return Ok(CheckResult::NotConfigured) }
    } else {
        if !common::content_is(p, common::param_str(params, "content", "")) { return Ok(CheckResult::NotConfigured) }
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
    let want = want_sha(params)?
    if !common::want_present(params)? {
        if !common::lexists(p) { return Ok(ApplyResult::Success) }
        if fs::read_link(p).is_err() && fs::is_dir(p) { return Err("path is a directory; use linux_files.directory with ensure = :absent") }
        log::info("deleting " + p)
        fs::delete(p)?
        return Ok(ApplyResult::Success)
    }
    fs::mkdir(path::parent(p))?
    let tmp = common::tmp_sibling(p)
    if url != "" {
        // Only fetch when the file is missing or fails its digest — keeps a
        // metadata-only fix (mode/owner) from re-downloading.
        let need = !fs::is_file(p) || (want != "" && hash::sha256_file(p)? != want)
        if need {
            // Download beside the target and verify before it goes live, so
            // a bad digest never replaces (or creates) the file at `path`.
            log::info("downloading " + url + " -> " + p)
            if let Err(e) = http::download(url, tmp, Value::Null) {
                fs::delete(tmp).unwrap_or(())
                return Err("downloading " + url + ": " + e)
            }
            if want != "" {
                let got = hash::sha256_file(tmp)?
                if got != want {
                    fs::delete(tmp).unwrap_or(())
                    return Err("downloaded file sha256 mismatch: expected " + want + ", got " + got)
                }
            }
            common::install_tmp(tmp, p)?
        }
    } else {
        log::info("writing " + p)
        fs::write(tmp, common::param_str(params, "content", ""))?
        common::install_tmp(tmp, p)?
    }
    common::apply_attrs(p, a)?
    Ok(ApplyResult::Success)
}
