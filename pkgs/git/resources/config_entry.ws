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

fn config_path(params: Value) -> Result[string, string] {
    let scope = param_str(params, "scope", "global")
    if scope == "system" { return Ok("/etc/gitconfig") }
    if scope != "global" { return Err("invalid 'scope' value '" + scope + "' (expected global or system)") }
    let h = param_str(params, "home", "")
    let home = if h != "" { h } else { env::home_dir() }
    Ok(home + "/.gitconfig")
}

// "user.name" -> [user] name; "branch.main.rebase" -> [branch "main"] rebase.
// Returns [section_header, key_name].
fn split_key(dotted: string) -> Result[List[string], string] {
    let parts = dotted.split(".")
    if parts.len() < 2 || parts.get(0).unwrap_or("") == "" || parts.get(parts.len() - 1).unwrap_or("") == "" {
        return Err("invalid git config key '" + dotted + "' (expected section.key or section.subsection.key)")
    }
    let section = parts.get(0).unwrap_or("")
    let key = parts.get(parts.len() - 1).unwrap_or("")
    if parts.len() == 2 { return Ok(["[" + section + "]", key]) }
    let mid = parts.slice(1, parts.len() - 1).join(".")
    Ok(["[" + section + " \"" + mid + "\"]", key])
}

fn is_key_line(trimmed: string, key: string) -> bool {
    trimmed.starts_with(key + " =") || trimmed.starts_with(key + "=")
}

fn set_entry(text: string, section: string, key: string, value: string) -> string {
    let entry = "\t" + key + " = " + value
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
                out = out + entry + "\n"
                key_written = true
            }
            in_section = trimmed == section
            if in_section { section_seen = true }
            out = out + line + "\n"
        } else if in_section && is_key_line(trimmed, key) {
            if !key_written {
                out = out + entry + "\n"
                key_written = true
            }
        } else {
            out = out + line + "\n"
        }
    }

    if in_section && !key_written {
        out = out + entry + "\n"
    } else if !section_seen {
        out = out + section + "\n" + entry + "\n"
    }
    out
}

// Drop the key's line from its section; the section header stays even when
// it ends up empty (harmless to git, and cheap to reason about).
fn remove_entry(text: string, section: string, key: string) -> string {
    let lines = text.split("\n")
    let out = ""
    let in_section = false

    for i in 0..lines.len() {
        let line = lines[i]
        if i == lines.len() - 1 && line == "" { continue }
        let trimmed = line.trim()
        if trimmed.starts_with("[") && trimmed.ends_with("]") {
            in_section = trimmed == section
            out = out + line + "\n"
        } else if in_section && is_key_line(trimmed, key) {
            continue
        } else {
            out = out + line + "\n"
        }
    }
    out
}

fn desired(params: Value, current: string) -> Result[string, string] {
    let parts = split_key(param_str(params, "key", ""))?
    let section = parts.get(0).unwrap_or("")
    let key = parts.get(1).unwrap_or("")
    if !want_present(params)? {
        return Ok(remove_entry(current, section, key))
    }
    let value = param_str(params, "value", "")
    if value == "" { return Err("missing 'value' parameter") }
    Ok(set_entry(current, section, key, value))
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
