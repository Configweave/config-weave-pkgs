use value
use env
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

fn home(params: Value) -> string {
    let h = param_str(params, "home", "")
    if h != "" { h } else { env::home_dir() }
}

fn target(params: Value) -> string { home(params) + "/.config/tmux/tmux.conf" }

fn bind_line(params: Value) -> Result[string, string] {
    let key = param_str(params, "key", "")
    let command = param_str(params, "command", "")
    if key == "" { return Err("missing 'key' parameter") }
    if command == "" { return Err("missing 'command' parameter") }
    if param_bool(params, "prefix", true) {
        Ok("bind-key " + key + " " + command)
    } else {
        Ok("bind-key -n " + key + " " + command)
    }
}

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") { if l == line { return true } }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = target(params)
    let line = bind_line(params)?
    if fs::is_file(p) && has_line(fs::read(p)?, line) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = target(params)
    let line = bind_line(params)?
    fs::mkdir(path::parent(p))?
    let text = if fs::is_file(p) { fs::read(p)? } else { "" }
    if !has_line(text, line) {
        let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
        fs::write(p, text + sep + line + "\n")?
    }
    Ok(ApplyResult::Success)
}
