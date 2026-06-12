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

fn clean_name(name: string) -> Result[string, string] {
    if name == "" { return Err("missing 'name' parameter") }
    if name.starts_with("/") || name.contains("..") || name.contains("/") { return Err("name must be a simple filename") }
    if name.ends_with(".desktop") { Ok(name) } else { Ok(name + ".desktop") }
}

fn target(params: Value) -> Result[string, string] {
    Ok(home(params) + "/.config/autostart/" + clean_name(param_str(params, "name", ""))?)
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

