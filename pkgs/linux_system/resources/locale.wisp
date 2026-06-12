use value
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn check(params: Value) -> Result[CheckResult, string] {
    let content = param_str(params, "content", "")
    if fs::is_file("/etc/locale.conf") && fs::read("/etc/locale.conf")? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    fs::write("/etc/locale.conf", param_str(params, "content", ""))?
    Ok(ApplyResult::Success)
}

