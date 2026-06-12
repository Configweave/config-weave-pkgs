use value
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn desired(params: Value) -> string {
    param_str(params, "ip", "") + " " + param_str(params, "names", "")
}

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") { if l.trim() == line { return true } }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let ip = param_str(params, "ip", "")
    let names = param_str(params, "names", "")
    if ip == "" { return Err("missing 'ip' parameter") }
    if names == "" { return Err("missing 'names' parameter") }
    if fs::is_file("/etc/hosts") && has_line(fs::read("/etc/hosts")?, desired(params)) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let line = desired(params)
    let text = if fs::is_file("/etc/hosts") { fs::read("/etc/hosts")? } else { "" }
    if !has_line(text, line) {
        let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
        fs::write("/etc/hosts", text + sep + line + "\n")?
    }
    Ok(ApplyResult::Success)
}

