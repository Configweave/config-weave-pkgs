use value
use fs
use path
use shell
use common

fn unit_path(name: string) -> string { "/etc/systemd/system/" + name }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    let content = common::param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = unit_path(name)
    if fs::is_file(p) && fs::read(p)? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    let content = common::param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = unit_path(name)
    fs::mkdir(path::parent(p))?
    fs::write(p, content)?
    if common::param_bool(params, "daemon_reload", false) && (fs::exists("/bin/systemctl") || fs::exists("/usr/bin/systemctl")) {
        let out = shell::run("systemctl daemon-reload", Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}

