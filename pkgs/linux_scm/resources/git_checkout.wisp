use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn check(params: Value) -> Result[CheckResult, string] {
    let dest = param_str(params, "dest", "")
    let ref = param_str(params, "ref", "")
    if param_str(params, "repo", "") == "" { return Err("missing 'repo' parameter") }
    if dest == "" { return Err("missing 'dest' parameter") }
    if !fs::is_dir(dest + "/.git") { return Ok(CheckResult::NotConfigured) }
    if ref == "" { return Ok(CheckResult::AlreadyConfigured) }
    let head = shell::bash("git -C " + q(dest) + " rev-parse HEAD 2>/dev/null", Value::Null)?
    let target = shell::bash("git -C " + q(dest) + " rev-parse " + q(ref) + " 2>/dev/null", Value::Null)?
    if !head.success || !target.success { return Ok(CheckResult::NotConfigured) }
    if head.stdout.trim() == target.stdout.trim() { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let repo = param_str(params, "repo", "")
    let dest = param_str(params, "dest", "")
    let ref = param_str(params, "ref", "")
    let force = param_bool(params, "force", false)
    if repo == "" { return Err("missing 'repo' parameter") }
    if dest == "" { return Err("missing 'dest' parameter") }
    if !fs::is_dir(dest + "/.git") {
        fs::mkdir(path::parent(dest))?
        let depth = param_int(params, "depth", 0)
        let darg = if depth > 0 { " --depth " + str(depth) } else { "" }
        let clone = shell::bash("git clone" + darg + " " + q(repo) + " " + q(dest), Value::Null)?
        if !clone.success { return Err(clone.stderr.trim()) }
    } else {
        let fetch = shell::bash("git -C " + q(dest) + " fetch --all --tags --prune", Value::Null)?
        if !fetch.success { return Err(fetch.stderr.trim()) }
    }
    if ref != "" {
        let co = shell::bash("git -C " + q(dest) + " checkout " + q(ref), Value::Null)?
        if !co.success { return Err(co.stderr.trim()) }
    }
    if force {
        let target = if ref != "" { ref } else { "HEAD" }
        let reset = shell::bash("git -C " + q(dest) + " reset --hard " + q(target), Value::Null)?
        if !reset.success { return Err(reset.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}
