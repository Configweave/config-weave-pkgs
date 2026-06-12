use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }
fn conf_path(name: string) -> string { "/etc/ssh/sshd_config.d/" + name }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let content = param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = conf_path(name)
    if fs::is_file(p) && fs::read(p)? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = conf_path(param_str(params, "name", ""))
    fs::mkdir(path::parent(p))?
    fs::write(p, param_str(params, "content", ""))?
    if param_bool(params, "validate", true) && (fs::exists("/usr/sbin/sshd") || fs::exists("/usr/bin/sshd")) {
        let out = shell::bash("sshd -t -f /etc/ssh/sshd_config", Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}

