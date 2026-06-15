use value
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
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
    if !fs::exists(p) { return Ok(CheckResult::AlreadyConfigured) }
    if has_line(fs::read(p)?, line) { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    let line = param_str(params, "line", "")
    if p == "" { return Err("missing 'path' parameter") }
    if line == "" { return Err("missing 'line' parameter") }
    if !fs::exists(p) { return Ok(ApplyResult::Success) }
    fs::write(p, without_line(fs::read(p)?, line))?
    Ok(ApplyResult::Success)
}
