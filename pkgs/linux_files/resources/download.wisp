use value
use fs
use path
use http
use hash
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn norm_mode(mode: string) -> string {
    let m = mode.trim()
    if m.starts_with("0") && m.len() > 1 { return m.slice(1, m.len()) }
    m
}

fn attrs_ok(p: string, mode: string, owner: string, group: string) -> Result[bool, string] {
    let out = shell::bash("stat -c '%a %U %G' " + q(p), Value::Null)?
    if !out.success { return Ok(false) }
    let parts = out.stdout.trim().split(" ")
    if mode != "" && parts.get(0).unwrap_or("") != norm_mode(mode) { return Ok(false) }
    if owner != "" && parts.get(1).unwrap_or("") != owner { return Ok(false) }
    if group != "" && parts.get(2).unwrap_or("") != group { return Ok(false) }
    Ok(true)
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

fn check(params: Value) -> Result[CheckResult, string] {
    let dest = param_str(params, "dest", "")
    let want = param_str(params, "sha256", "")
    if dest == "" { return Err("missing 'dest' parameter") }
    if !fs::is_file(dest) { return Ok(CheckResult::NotConfigured) }
    if want != "" && hash::sha256_file(dest)? != want { return Ok(CheckResult::NotConfigured) }
    if !attrs_ok(dest, param_str(params, "mode", ""), param_str(params, "owner", ""), param_str(params, "group", ""))? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let url = param_str(params, "url", "")
    let dest = param_str(params, "dest", "")
    if url == "" { return Err("missing 'url' parameter") }
    if dest == "" { return Err("missing 'dest' parameter") }
    let want = param_str(params, "sha256", "")
    // Only fetch when the file is missing or fails its digest — keeps a
    // metadata-only fix (mode/owner) from re-downloading.
    let need = !fs::is_file(dest) || (want != "" && hash::sha256_file(dest)? != want)
    if need {
        fs::mkdir(path::parent(dest))?
        http::download(url, dest, Value::Null)?
        if want != "" && hash::sha256_file(dest)? != want { return Err("downloaded file sha256 mismatch") }
    }
    apply_attrs(dest, param_str(params, "mode", ""), param_str(params, "owner", ""), param_str(params, "group", ""))?
    Ok(ApplyResult::Success)
}
