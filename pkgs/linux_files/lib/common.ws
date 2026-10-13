use value
use shell

// Helpers shared by linux_files' resources and gatherers. Imported with
// `use common`; nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

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
