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

fn reject_rel(p: string, label: string) -> Result[unit, string] {
    if p == "" { return Err("missing '" + label + "' parameter") }
    if p.starts_with("/") || p.contains("..") { return Err(label + " must be relative and must not contain '..'") }
    Ok(())
}

fn target(params: Value) -> Result[string, string] {
    let theme = param_str(params, "theme", "")
    let rel = param_str(params, "relative_path", "")
    reject_rel(theme, "theme")?
    reject_rel(rel, "relative_path")?
    Ok(home(params) + "/.local/share/plasma/desktoptheme/" + theme + "/" + rel)
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

