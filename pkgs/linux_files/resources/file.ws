use value
use fs
use path
use shell
use http
use hash
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) {
        if let Some(s) = v.as_string() { return s }
    }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// url mode and content mode are mutually exclusive; sha256 only makes sense
// alongside a url.
fn source_url(params: Value) -> Result[string, string] {
    let url = param_str(params, "url", "")
    if url != "" && param_str(params, "content", "") != "" {
        return Err("'url' and 'content' are mutually exclusive")
    }
    if url == "" && param_str(params, "sha256", "") != "" {
        return Err("'sha256' requires 'url'")
    }
    Ok(url)
}

fn norm_mode(mode: string) -> string {
    let m = mode.trim()
    if m.starts_with("0") && m.len() > 1 { return m.slice(1, m.len()) }
    m
}

fn apply_attrs(p: string, mode: string, owner: string, group: string) -> Result[unit, string] {
    if mode != "" {
        let out = shell::run("chmod " + mode + " " + p, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    if owner != "" || group != "" {
        let spec = if owner != "" && group != "" { owner + ":" + group } else if owner != "" { owner } else { ":" + group }
        let out = shell::run("chown " + spec + " " + p, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(())
}

fn attrs_ok(p: string, mode: string, owner: string, group: string) -> Result[bool, string] {
    let cmd = "stat -c '%a %U %G' " + q(p)
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Ok(false) }
    let parts = out.stdout.trim().split(" ")
    if mode != "" && parts.get(0).unwrap_or("") != norm_mode(mode) { return Ok(false) }
    if owner != "" && parts.get(1).unwrap_or("") != owner { return Ok(false) }
    if group != "" && parts.get(2).unwrap_or("") != group { return Ok(false) }
    Ok(true)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    let url = source_url(params)?
    if !want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if url != "" {
        let want = param_str(params, "sha256", "")
        if want != "" && hash::sha256_file(p)? != want { return Ok(CheckResult::NotConfigured) }
    } else {
        if fs::read(p)? != param_str(params, "content", "") { return Ok(CheckResult::NotConfigured) }
    }
    if !attrs_ok(p, param_str(params, "mode", ""), param_str(params, "owner", ""), param_str(params, "group", ""))? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    let url = source_url(params)?
    if !want_present(params)? {
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        if fs::is_dir(p) { return Err("path is a directory; use linux_files.directory with ensure = :absent") }
        log::info("deleting " + p)
        fs::delete(p)?
        return Ok(ApplyResult::Success)
    }
    if url != "" {
        let want = param_str(params, "sha256", "")
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
        fs::write(p, param_str(params, "content", ""))?
    }
    apply_attrs(p, param_str(params, "mode", ""), param_str(params, "owner", ""), param_str(params, "group", ""))?
    Ok(ApplyResult::Success)
}
