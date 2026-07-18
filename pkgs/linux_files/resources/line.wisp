use value
use fs
use path

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

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

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") {
        if l == line { return true }
    }
    false
}

fn without_line(text: string, line: string) -> string {
    let kept = []
    for l in text.split("\n") {
        if l != line { kept.push(l) }
    }
    kept.join("\n")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    let line = param_str(params, "line", "")
    if p == "" { return Err("missing 'path' parameter") }
    if line == "" { return Err("missing 'line' parameter") }
    if !want_present(params)? {
        if !fs::exists(p) { return Ok(CheckResult::AlreadyConfigured) }
        if has_line(fs::read(p)?, line) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    if has_line(fs::read(p)?, line) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    let line = param_str(params, "line", "")
    if p == "" { return Err("missing 'path' parameter") }
    if line == "" { return Err("missing 'line' parameter") }
    if !want_present(params)? {
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        fs::write(p, without_line(fs::read(p)?, line))?
        return Ok(ApplyResult::Success)
    }
    if !fs::exists(p) {
        if !param_bool(params, "create", true) { return Err("file does not exist and create is false") }
        fs::mkdir(path::parent(p))?
        fs::write(p, "")?
    }
    let text = fs::read(p)?
    if !has_line(text, line) {
        let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
        fs::write(p, text + sep + line + "\n")?
    }
    Ok(ApplyResult::Success)
}
