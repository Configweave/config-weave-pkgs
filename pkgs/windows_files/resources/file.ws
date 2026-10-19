use value
use fs
use path
use http
use hash
use time
use log
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
    if sha != "" && hash::sha256_file(p)?.to_lower() != sha { return Ok(false) }
    Ok(true)
}

// One download attempt into `tmp`: Ok("") when the file arrived whole,
// Ok(reason) for a failure worth retrying (a transport error, a short or
// long file), Err for one that is not (a digest mismatch on a file of the
// right size).
fn fetch(url: string, tmp: string, size: int, sha: string) -> Result[string, string] {
    if fs::lexists(tmp) { fs::delete(tmp)? }
    let got = http::download(url, tmp, Value::Null)
    if let Err(e) = got { return Ok(e) }
    let have = file_size(tmp)?
    if size > 0 && have != size {
        return Ok("got " + str(have) + " bytes, expected " + str(size))
    }
    if sha != "" {
        let digest = hash::sha256_file(tmp)?.to_lower()
        if digest != sha {
            return Err("downloaded file sha256 mismatch: expected " + sha + ", got " + digest)
        }
    }
    Ok("")
}

// Downloads `url` to a fixed temp name beside `p`, retrying a failed or
// short download, and only then puts it in place. The file at `p` is only
// ever a finished, verified download: an interrupted run leaves at most the
// temp file, which the next run deletes before it starts again.
fn download(p: string, url: string, size: int, sha: string, retries: int) -> Result[unit, string] {
    fs::mkdir(path::parent(p))?
    let tmp = p + ".config-weave-download"
    let attempt = 0
    let reason = ""
    while true {
        attempt = attempt + 1
        log::info("downloading " + url + " -> " + p + " (attempt " + str(attempt) + " of " + str(retries + 1) + ")")
        let r = fetch(url, tmp, size, sha)
        if let Err(e) = r {
            fs::delete(tmp).unwrap_or(())
            return Err(e)
        }
        reason = r.unwrap_or("")
        if reason == "" { break }
        if attempt > retries {
            fs::delete(tmp).unwrap_or(())
            return Err("downloading " + url + " failed after " + str(attempt) + " attempt(s): " + reason)
        }
        log::warn("download attempt " + str(attempt) + " failed: " + reason)
        time::sleep(5000 * attempt)
    }
    install(tmp, p)
}

// Puts the verified temp file in place. A new file is renamed into place.
// An existing file is swapped with ReplaceFile, which is as atomic as a
// rename but keeps the old file's security descriptor and attributes, so
// explicit NTFS rules set by windows_files.permissions survive. A link at
// `p` is written through, so the link itself stays.
fn install(tmp: string, p: string) -> Result[unit, string] {
    let r = if fs::read_link(p).is_ok() {
        fs::copy(tmp, p)
    } else if fs::is_file(p) {
        common::ps_run("replacing " + p, "[System.IO.File]::Replace(" + common::ps_q(tmp) + ", " + common::ps_q(p) + ", [NullString]::Value)\n")
    } else {
        fs::move(tmp, p)
    }
    if fs::lexists(tmp) { fs::delete(tmp).unwrap_or(()) }
    r
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
    let sha = want_sha(params)?
    let size = want_size(params)?
    want_retries(params)?
    let content = common::with_line_endings(params, common::param_str(params, "content", ""))?
    if !common::want_present(params)? {
        if fs::lexists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    not_a_dir(p)?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if url != "" {
        if !passes(p, size, sha)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !common::content_is(p, content) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let url = source_url(params)?
    let sha = want_sha(params)?
    let size = want_size(params)?
    let retries = want_retries(params)?
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
    download(p, url, size, sha, retries)?
    Ok(ApplyResult::Success)
}
