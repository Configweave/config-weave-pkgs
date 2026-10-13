use value
use common
use fs
use shell

fn require_firewalld() -> Result[unit, string] {
    if fs::exists("/usr/bin/firewall-cmd") || fs::exists("/bin/firewall-cmd") { return Ok(()) }
    Err("firewall-cmd not found; is firewalld installed?")
}

fn base_args(params: Value) -> string {
    let args = ""
    if common::param_bool(params, "permanent", true) { args = args + " --permanent" }
    let zone = common::param_str(params, "zone", "")
    if zone != "" { args = args + " --zone=" + common::q(zone) }
    args
}

// The rule kind is whichever single selector param is set.
fn selector(params: Value) -> Result[List[string], string] {
    let kinds = []
    let service = common::param_str(params, "service", "")
    let port = common::param_str(params, "port", "")
    let source = common::param_str(params, "source", "")
    let rich = common::param_str(params, "rich_rule", "")
    if service != "" { kinds.push(["service", service]) }
    if port != "" { kinds.push(["port", port]) }
    if source != "" { kinds.push(["source", source]) }
    if rich != "" { kinds.push(["rich-rule", rich]) }
    if kinds.len() != 1 {
        return Err("exactly one of 'service', 'port', 'source' or 'rich_rule' must be set")
    }
    Ok(kinds.get(0).expect("selector checked non-empty"))
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_firewalld()?
    let sel = selector(params)?
    let kind = sel.get(0).unwrap_or("")
    let val = sel.get(1).unwrap_or("")
    let out = shell::bash("firewall-cmd" + base_args(params) + " --query-" + kind + "=" + common::q(val), Value::Null)?
    if out.success == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_firewalld()?
    let sel = selector(params)?
    let kind = sel.get(0).unwrap_or("")
    let val = sel.get(1).unwrap_or("")
    let verb = if common::want_present(params)? { " --add-" } else { " --remove-" }
    let out = shell::bash("firewall-cmd" + base_args(params) + verb + kind + "=" + common::q(val), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
