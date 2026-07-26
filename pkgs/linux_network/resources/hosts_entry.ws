use value
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn names(params: Value) -> Result[List[string], string] {
    if let Some(v) = params.get("names") {
        if let Some(l) = v.as_list() {
            let out = []
            for item in l {
                if let Some(s) = item.as_string() { if s != "" { out.push(s) } }
            }
            if !out.is_empty() { return Ok(out) }
        }
    }
    Err("missing 'names' parameter (a non-empty list of host names)")
}

fn desired(params: Value) -> Result[string, string] {
    Ok(param_str(params, "ip", "") + " " + names(params)?.join(" "))
}

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") { if l.trim() == line { return true } }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let ip = param_str(params, "ip", "")
    if ip == "" { return Err("missing 'ip' parameter") }
    if fs::is_file("/etc/hosts") && has_line(fs::read("/etc/hosts")?, desired(params)?) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let ip = param_str(params, "ip", "")
    if ip == "" { return Err("missing 'ip' parameter") }
    let line = desired(params)?
    let text = if fs::is_file("/etc/hosts") { fs::read("/etc/hosts")? } else { "" }
    if !has_line(text, line) {
        let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
        fs::write("/etc/hosts", text + sep + line + "\n")?
    }
    Ok(ApplyResult::Success)
}
