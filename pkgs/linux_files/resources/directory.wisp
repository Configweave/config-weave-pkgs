use value
use fs
use shell
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn norm_mode(mode: string) -> string {
    let m = mode.trim()
    if m.starts_with("0") && m.len() > 1 { return m.slice(1, m.len()) }
    m
}

fn attrs_ok(p: string, mode: string, owner: string, group: string) -> Result[bool, string] {
    if mode == "" && owner == "" && group == "" { return Ok(true) }
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
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_dir(p) { return Ok(CheckResult::NotConfigured) }
    if !attrs_ok(p, param_str(params, "mode", ""), param_str(params, "owner", ""), param_str(params, "group", ""))? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        if !fs::is_dir(p) { return Err("path is not a directory; use linux_files.file with ensure = :absent") }
        if !param_bool(params, "recursive", false) {
            return Err("path is a directory; set recursive = true to remove it")
        }
        log::info("deleting directory " + p)
        fs::delete_dir(p)?
        return Ok(ApplyResult::Success)
    }
    log::info("creating directory " + p)
    fs::mkdir(p)?
    apply_attrs(p, param_str(params, "mode", ""), param_str(params, "owner", ""), param_str(params, "group", ""))?
    Ok(ApplyResult::Success)
}
