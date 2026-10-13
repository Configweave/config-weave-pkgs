use value
use fs
use shell
use path
use common

fn dropin_path(key: string) -> string { "/etc/sysctl.d/99-config-weave-" + key.replace(".", "-") + ".conf" }

fn check(params: Value) -> Result[CheckResult, string] {
    let key = common::param_str(params, "key", "")
    let want = common::param_str(params, "value", "")
    if key == "" { return Err("missing 'key' parameter") }
    let out = shell::bash("sysctl -n " + common::q(key), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    if out.stdout.trim() != want { return Ok(CheckResult::NotConfigured) }
    let p = dropin_path(key)
    if !fs::is_file(p) || fs::read(p)? != key + " = " + want + "\n" { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = common::param_str(params, "key", "")
    let want = common::param_str(params, "value", "")
    if key == "" { return Err("missing 'key' parameter") }
    let out = shell::bash("sysctl -w " + common::q(key + "=" + want), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let p = dropin_path(key)
    fs::mkdir(path::parent(p))?
    fs::write(p, key + " = " + want + "\n")?
    Ok(ApplyResult::Success)
}
