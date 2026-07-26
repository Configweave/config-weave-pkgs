use value
use fs
use archive

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

// Idempotence marker: the dest directory exists and is non-empty.
fn extracted(dest: string) -> Result[bool, string] {
    if !fs::is_dir(dest) { return Ok(false) }
    Ok(!fs::list_dir(dest)?.is_empty())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let dest = param_str(params, "dest", "")
    if dest == "" { return Err("missing 'dest' parameter") }
    if extracted(dest)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let src = param_str(params, "src", "")
    let dest = param_str(params, "dest", "")
    if src == "" { return Err("missing 'src' parameter") }
    if dest == "" { return Err("missing 'dest' parameter") }
    if !fs::is_file(src) { return Err("archive does not exist: " + src) }
    fs::mkdir(dest)?
    archive::extract(src, dest)?
    Ok(ApplyResult::Success)
}
