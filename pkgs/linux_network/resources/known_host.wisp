use value
use fs
use path
use env

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn kh_path(params: Value) -> string {
    let p = param_str(params, "path", "")
    if p != "" { return p }
    let home = param_str(params, "home", "")
    let h = if home != "" { home } else { env::home_dir() }
    h + "/.ssh/known_hosts"
}

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") {
        if l == line { return true }
    }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let key = param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    let p = kh_path(params)
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    if has_line(fs::read(p)?, key) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    let p = kh_path(params)
    fs::mkdir(path::parent(p))?
    let text = if fs::exists(p) { fs::read(p)? } else { "" }
    if !has_line(text, key) {
        let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
        fs::write(p, text + sep + key + "\n")?
    }
    Ok(ApplyResult::Success)
}
