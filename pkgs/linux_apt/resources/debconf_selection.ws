use value
use shell
use common

fn check(params: Value) -> Result[CheckResult, string] {
    let package = common::param_str(params, "package", "")
    let question = common::param_str(params, "question", "")
    let value = common::param_str(params, "value", "")
    if package == "" { return Err("missing 'package' parameter") }
    if question == "" { return Err("missing 'question' parameter") }
    // Ask debconf for the current answer: a "0 <value>" reply means set.
    let out = shell::bash("printf 'get %s\\n' " + common::q(question) + " | debconf-communicate " + common::q(package) + " 2>/dev/null", Value::Null)?
    if !out.success { return Ok(CheckResult::NotConfigured) }
    let resp = out.stdout.trim()
    if resp.starts_with("0 ") && resp.slice(2, resp.len()) == value { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let package = common::param_str(params, "package", "")
    let question = common::param_str(params, "question", "")
    let vtype = common::param_str(params, "vtype", "string")
    let value = common::param_str(params, "value", "")
    if package == "" { return Err("missing 'package' parameter") }
    if question == "" { return Err("missing 'question' parameter") }
    let line = package + " " + question + " " + vtype + " " + value
    let out = shell::bash("echo " + common::q(line) + " | debconf-set-selections", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
