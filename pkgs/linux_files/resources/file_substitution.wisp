use value
use fs

// Literal find/replace in a file. wisp has no regex module, so `pattern`
// is a literal substring (not a regular expression); `replacement` must
// not itself contain `pattern`, or the resource can never converge.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    let pattern = param_str(params, "pattern", "")
    if p == "" { return Err("missing 'path' parameter") }
    if pattern == "" { return Err("missing 'pattern' parameter") }
    if !fs::is_file(p) { return Err("file does not exist: " + p) }
    if fs::read(p)?.contains(pattern) { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    let pattern = param_str(params, "pattern", "")
    let replacement = param_str(params, "replacement", "")
    if p == "" { return Err("missing 'path' parameter") }
    if pattern == "" { return Err("missing 'pattern' parameter") }
    if !fs::is_file(p) { return Err("file does not exist: " + p) }
    fs::write(p, fs::read(p)?.replace(pattern, replacement))?
    Ok(ApplyResult::Success)
}
