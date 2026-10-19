use value
use fs
use path
use http
use hash
use log
use time
use common

// url mode and content mode are mutually exclusive; sha256 and size only
// make sense alongside a url.
fn source_url(params: Value) -> Result[string, string] {
    let url = common::param_str(params, "url", "")
    if url != "" && common::param_str(params, "content", "") != "" {
        return Err("'url' and 'content' are mutually exclusive")
    }
    if url == "" && common::param_str(params, "sha256", "") != "" {
        return Err("'sha256' requires 'url'")
    }
    if url == "" && common::param_int(params, "size", 0) != 0 {
        return Err("'size' requires 'url'")
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

// The expected size in bytes; 0 when none was given.
fn want_size(params: Value) -> Result[int, string] {
    let size = common::param_int(params, "size", 0)
    if size < 0 { return Err("invalid 'size' " + str(size) + " (expected a byte count, or 0 for unchecked)") }
    Ok(size)
}

fn want_retries(params: Value) -> Result[int, string] {
    let retries = common::param_int(params, "retries", 3)
    if retries < 0 || retries > 10 { return Err("invalid 'retries' " + str(retries) + " (expected 0 to 10)") }
    Ok(retries)
}

fn file_size(p: string) -> Result[int, string] {
    let meta = fs::metadata(p)?
    if let Some(v) = meta.get("size") { if let Some(n) = v.as_int() { return Ok(n) } }
    Err("cannot read the size of '" + p + "'")
}

// Whether the file at `p` passes the size and digest that were given. The
// size is compared first and costs nothing, so a large file with only
// `size` set is never hashed.
fn passes(p: string, size: int, sha: string) -> Result[bool, string] {
    if size > 0 && file_size(p)? != size { return Ok(false) }
    if sha != "" && hash::sha256_file(p)? != sha { return Ok(false) }
    Ok(true)
}

// One download attempt into `tmp`: Ok("") when the file arrived whole,
// Ok(reason) for a failure worth retrying (a transport error, a file of
// the wrong size), Err for one that is not (a digest mismatch on a file of
// the right size).
fn fetch(url: string, tmp: string, size: int, sha: string) -> Result[string, string] {
    if fs::lexists(tmp) { fs::delete(tmp)? }
    let got = http::download(url, tmp, Value::Null)
    if let Err(e) = got { return Ok(e) }
    let have = file_size(tmp)?
    if size > 0 && have != size {
        return Ok("got " + str(have) + " bytes, expected " + str(size))
    }
    if sha != "" {
        let digest = hash::sha256_file(tmp)?
        if digest != sha {
            return Err("downloaded file sha256 mismatch: expected " + sha + ", got " + digest)
        }
    }
    Ok("")
}

// Downloads to the temp file beside the target, retrying a failed or short
// download, so the file at `p` is only ever a finished, verified download.
// An interrupted run leaves at most the temp file, which the next attempt
// deletes before it starts.
fn download(url: string, tmp: string, size: int, sha: string, retries: int) -> Result[unit, string] {
    let attempt = 0
    while true {
        attempt = attempt + 1
        log::info("downloading " + url + " (attempt " + str(attempt) + " of " + str(retries + 1) + ")")
        let r = fetch(url, tmp, size, sha)
        if let Err(e) = r {
            fs::delete(tmp).unwrap_or(())
            return Err(e)
        }
        let reason = r.unwrap_or("")
        if reason == "" { return Ok(()) }
        if attempt > retries {
            fs::delete(tmp).unwrap_or(())
            return Err("downloading " + url + " failed after " + str(attempt) + " attempt(s): " + reason)
        }
        log::warn("download attempt " + str(attempt) + " failed: " + reason)
        time::sleep(5000 * attempt)
    }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let a = common::attrs(params)?
    let url = source_url(params)?
    let want = want_sha(params)?
    let size = want_size(params)?
    want_retries(params)?
    if !common::want_present(params)? {
        if fs::lexists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if url != "" {
        if !passes(p, size, want)? { return Ok(CheckResult::NotConfigured) }
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
    let size = want_size(params)?
    let retries = want_retries(params)?
    if !common::want_present(params)? {
        if !fs::lexists(p) { return Ok(ApplyResult::Success) }
        if fs::read_link(p).is_err() && fs::is_dir(p) { return Err("path is a directory; use linux_files.directory with ensure = :absent") }
        log::info("deleting " + p)
        fs::delete(p)?
        return Ok(ApplyResult::Success)
    }
    fs::mkdir(path::parent(p))?
    let tmp = common::tmp_sibling(p)
    if url != "" {
        // Only fetch when the file is missing or fails its size or digest:
        // keeps a metadata-only fix (mode/owner) from re-downloading.
        if !fs::is_file(p) || !passes(p, size, want)? {
            log::info("fetching " + url + " -> " + p)
            download(url, tmp, size, want, retries)?
            common::install_tmp(tmp, p, a)?
        }
    } else {
        log::info("writing " + p)
        fs::write(tmp, common::param_str(params, "content", ""))?
        common::install_tmp(tmp, p, a)?
    }
    common::apply_attrs(p, a)?
    Ok(ApplyResult::Success)
}
