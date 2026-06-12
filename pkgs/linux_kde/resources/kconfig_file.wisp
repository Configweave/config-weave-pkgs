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

fn target(params: Value) -> Result[string, string] {
    let f = param_str(params, "file", "")
    reject_rel(f)?
    Ok(home(params) + "/.config/" + f)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = target(params)?
    if fs::is_file(p) && fs::read(p)? == param_str(params, "content", "") {
        Ok(CheckResult::AlreadyConfigured)
    } else {
        Ok(CheckResult::NotConfigured)
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = target(params)?
    fs::mkdir(path::parent(p))?
    fs::write(p, param_str(params, "content", ""))?
    Ok(ApplyResult::Success)
}

