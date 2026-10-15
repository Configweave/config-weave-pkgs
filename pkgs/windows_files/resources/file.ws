use value
use fs
use path
use http
use hash
use time
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

fn not_a_dir(p: string) -> Result[unit, string] {
    if fs::is_dir(p) {
        return Err("'" + p + "' is a directory; windows_files.file manages files (use windows_files.directory for directories)")
    }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let url = source_url(params)?
    let want = want_sha(params)?
    let content = common::with_line_endings(params, common::param_str(params, "content", ""))?
    if !common::want_present(params)? {
        if fs::lexists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    not_a_dir(p)?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if url != "" {
        if want != "" && hash::sha256_file(p)?.to_lower() != want { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !common::content_is(p, content) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let url = source_url(params)?
    let want = want_sha(params)?
    let content = common::with_line_endings(params, common::param_str(params, "content", ""))?
    if !common::want_present(params)? {
        if !fs::lexists(p) { return Ok(ApplyResult::Success) }
        if fs::read_link(p).is_err() && fs::is_dir(p) { return Err("'" + p + "' is a directory; use windows_files.directory with ensure = :absent") }
        log::info("deleting " + p)
        fs::delete(p)?
        return Ok(ApplyResult::Success)
    }
    not_a_dir(p)?
    if url == "" {
        log::info("writing " + p)
        common::write_content(p, content)?
        return Ok(ApplyResult::Success)
    }
    // Download beside the target and verify before it goes live, so a bad
    // digest never replaces (or creates) the file at `path`. The verified
    // file is copied over the target rather than renamed onto it, which
    // keeps the target's own security descriptor.
    fs::mkdir(path::parent(p))?
    let tmp = p + ".config-weave-" + str(time::now_millis()) + ".tmp"
    log::info("downloading " + url + " -> " + p)
    if let Err(e) = http::download(url, tmp, Value::Null) {
        fs::delete(tmp).unwrap_or(())
        return Err("downloading " + url + ": " + e)
    }
    if want != "" {
        let got = hash::sha256_file(tmp)?.to_lower()
        if got != want {
            fs::delete(tmp).unwrap_or(())
            return Err("downloaded file sha256 mismatch: expected " + want + ", got " + got)
        }
    }
    let copied = fs::copy(tmp, p)
    fs::delete(tmp).unwrap_or(())
    copied?
    Ok(ApplyResult::Success)
}
