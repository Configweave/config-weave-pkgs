use value
use fs
use path
use http
use hash
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn check(params: Value) -> Result[CheckResult, string] {
    let dest = param_str(params, "dest", "")
    let want = param_str(params, "sha256", "")
    if dest == "" { return Err("missing 'dest' parameter") }
    if !fs::is_file(dest) { return Ok(CheckResult::NotConfigured) }
    if want != "" && hash::sha256_file(dest)? != want { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let url = param_str(params, "url", "")
    let dest = param_str(params, "dest", "")
    if url == "" { return Err("missing 'url' parameter") }
    if dest == "" { return Err("missing 'dest' parameter") }
    fs::mkdir(path::parent(dest))?
    http::download(url, dest, Value::Null)?
    let mode = param_str(params, "mode", "")
    if mode != "" {
        let out = shell::run("chmod " + mode + " " + dest, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    let want = param_str(params, "sha256", "")
    if want != "" && hash::sha256_file(dest)? != want { return Err("downloaded file sha256 mismatch") }
    Ok(ApplyResult::Success)
}

