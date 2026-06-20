use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// `choco source list --limit-output` prints "name|url|..." lines.
fn source_url(name: string) -> Result[string, string] {
    let out = shell::powershell("choco source list --limit-output 2>$null", Value::Null)?
    for line in out.stdout.split("\n") {
        let t = line.trim()
        if t.starts_with(name + "|") {
            let rest = t.slice(name.len() + 1, t.len())
            return Ok(rest.split("|").get(0).unwrap_or(""))
        }
    }
    Ok("")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let url = param_str(params, "url", "")
    if name == "" { return Err("missing 'name' parameter") }
    if url == "" { return Err("missing 'url' parameter") }
    if source_url(name)? == url { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let url = param_str(params, "url", "")
    if name == "" { return Err("missing 'name' parameter") }
    if url == "" { return Err("missing 'url' parameter") }
    let out = shell::powershell("choco source add --name=" + ps_q(name) + " --source=" + ps_q(url) + " -y; exit $LASTEXITCODE", Value::Null)?
    if !out.success { return Err(out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
