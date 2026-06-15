use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn check(params: Value) -> Result[CheckResult, string] {
    let dest = param_str(params, "dest", "")
    if param_str(params, "repo", "") == "" { return Err("missing 'repo' parameter") }
    if dest == "" { return Err("missing 'dest' parameter") }
    let revision = param_str(params, "revision", "")
    if !fs::is_dir(dest + "/.svn") { return Ok(CheckResult::NotConfigured) }
    if revision == "" { return Ok(CheckResult::AlreadyConfigured) }
    let out = shell::bash("svnversion -n " + q(dest) + " 2>/dev/null", Value::Null)?
    if out.success && out.stdout.trim() == revision { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let repo = param_str(params, "repo", "")
    let dest = param_str(params, "dest", "")
    let revision = param_str(params, "revision", "")
    if repo == "" { return Err("missing 'repo' parameter") }
    if dest == "" { return Err("missing 'dest' parameter") }
    let rarg = if revision != "" { " -r " + q(revision) } else { "" }
    let cmd = if !fs::is_dir(dest + "/.svn") {
        fs::mkdir(path::parent(dest))?
        "svn checkout" + rarg + " " + q(repo) + " " + q(dest)
    } else {
        "svn update" + rarg + " " + q(dest)
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
