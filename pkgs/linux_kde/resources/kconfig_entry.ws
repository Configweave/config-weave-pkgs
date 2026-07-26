use value
use env
use fs
use path

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn home(params: Value) -> string {
    let h = param_str(params, "home", "")
    if h != "" { h } else { env::home_dir() }
}

fn reject_rel(p: string) -> Result[unit, string] {
    if p == "" { return Err("path must not be empty") }
    if p.starts_with("/") || p.contains("..") { return Err("path must be relative and must not contain '..'") }
    Ok(())
}

fn config_path(params: Value) -> Result[string, string] {
    let f = param_str(params, "file", "")
    reject_rel(f)?
    Ok(home(params) + "/.config/" + f)
}

fn section_name(group: string, subgroup: string) -> string {
    if subgroup == "" { "[" + group + "]" } else { "[" + group + "][" + subgroup + "]" }
}

fn set_entry(text: string, section: string, key: string, value: string) -> string {
    let lines = text.split("\n")
    let out = ""
    let in_section = false
    let section_seen = false
    let key_written = false

    for i in 0..lines.len() {
        let line = lines[i]
        if i == lines.len() - 1 && line == "" {
            continue
        }
        let trimmed = line.trim()
        if trimmed.starts_with("[") && trimmed.ends_with("]") {
            if in_section && !key_written {
                out = out + key + "=" + value + "\n"
                key_written = true
            }
            in_section = trimmed == section
            if in_section { section_seen = true }
            out = out + line + "\n"
        } else if in_section && trimmed.starts_with(key + "=") {
            if !key_written {
                out = out + key + "=" + value + "\n"
                key_written = true
            }
        } else {
            out = out + line + "\n"
        }
    }

    if in_section && !key_written {
        out = out + key + "=" + value + "\n"
    } else if !section_seen {
        if out != "" && !out.ends_with("\n") { out = out + "\n" }
        out = out + section + "\n" + key + "=" + value + "\n"
    }
    out
}

// Drop the key's line from the target section; the section header stays even
// when it ends up empty (harmless in KConfig, and cheap to reason about).
fn remove_entry(text: string, section: string, key: string) -> string {
    let lines = text.split("\n")
    let out = ""
    let in_section = false

    for i in 0..lines.len() {
        let line = lines[i]
        if i == lines.len() - 1 && line == "" {
            continue
        }
        let trimmed = line.trim()
        if trimmed.starts_with("[") && trimmed.ends_with("]") {
            in_section = trimmed == section
            out = out + line + "\n"
        } else if in_section && trimmed.starts_with(key + "=") {
            continue
        } else {
            out = out + line + "\n"
        }
    }
    out
}

fn desired(params: Value, current: string) -> Result[string, string] {
    let group = param_str(params, "group", "")
    let key = param_str(params, "key", "")
    if group == "" { return Err("missing 'group' parameter") }
    if key == "" { return Err("missing 'key' parameter") }
    let section = section_name(group, param_str(params, "subgroup", ""))
    if !want_present(params)? {
        return Ok(remove_entry(current, section, key))
    }
    Ok(set_entry(current, section, key, param_str(params, "value", "")))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = config_path(params)?
    if !want_present(params)? && !fs::is_file(p) { return Ok(CheckResult::AlreadyConfigured) }
    let current = if fs::is_file(p) { fs::read(p)? } else { "" }
    if current == desired(params, current)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = config_path(params)?
    if !want_present(params)? && !fs::is_file(p) { return Ok(ApplyResult::Success) }
    let current = if fs::is_file(p) { fs::read(p)? } else { "" }
    fs::mkdir(path::parent(p))?
    fs::write(p, desired(params, current)?)?
    Ok(ApplyResult::Success)
}
