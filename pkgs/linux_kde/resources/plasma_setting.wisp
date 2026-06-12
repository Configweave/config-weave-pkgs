use value
use env
use fs
use path

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
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
        if i == lines.len() - 1 && line == "" { continue }
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
        out = out + section + "\n" + key + "=" + value + "\n"
    }
    out
}

fn target(params: Value) -> Result[string, string] {
    let f = param_str(params, "file", "plasmarc")
    reject_rel(f)?
    Ok(home(params) + "/.config/" + f)
}

fn desired(params: Value, current: string) -> Result[string, string] {
    let group = param_str(params, "group", "")
    let key = param_str(params, "key", "")
    if group == "" { return Err("missing 'group' parameter") }
    if key == "" { return Err("missing 'key' parameter") }
    Ok(set_entry(current, section_name(group, param_str(params, "subgroup", "")), key, param_str(params, "value", "")))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = target(params)?
    let current = if fs::is_file(p) { fs::read(p)? } else { "" }
    if current == desired(params, current)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = target(params)?
    let current = if fs::is_file(p) { fs::read(p)? } else { "" }
    fs::mkdir(path::parent(p))?
    fs::write(p, desired(params, current)?)?
    Ok(ApplyResult::Success)
}

