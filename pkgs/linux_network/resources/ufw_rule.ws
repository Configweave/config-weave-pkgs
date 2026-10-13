use value
use common
use fs
use shell

fn require_ufw() -> Result[unit, string] {
    if fs::exists("/usr/sbin/ufw") || fs::exists("/usr/bin/ufw") { return Ok(()) }
    Err("ufw not found; is it installed?")
}

fn rule_args(params: Value) -> Result[string, string] {
    let action = common::param_str(params, "action", "allow")
    if action != "allow" && action != "deny" && action != "reject" && action != "limit" {
        return Err("invalid 'action' value '" + action + "' (expected allow, deny, reject or limit)")
    }
    let port = common::param_str(params, "port", "")
    if port == "" { return Err("missing 'port' parameter") }
    let from = common::param_str(params, "from", "")
    if from == "" { return Ok(action + " " + port) }
    // "22/tcp" splits into a port + proto clause when a source is involved
    let parts = port.split("/")
    let portnum = parts.get(0).unwrap_or(port)
    let proto = parts.get(1).unwrap_or("")
    let proto_clause = if proto != "" { " proto " + proto } else { "" }
    Ok(action + " from " + from + " to any port " + portnum + proto_clause)
}

// `ufw show added` lists recorded rules as "ufw <args>" lines and works even
// while the firewall is inactive — unlike `ufw status`, which hides them.
fn rule_recorded(args: string) -> Result[bool, string] {
    let out = shell::bash("ufw show added", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    for line in out.stdout.split("\n") {
        if line.trim() == "ufw " + args { return Ok(true) }
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_ufw()?
    let recorded = rule_recorded(rule_args(params)?)?
    if recorded == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_ufw()?
    let args = rule_args(params)?
    let cmd = if common::want_present(params)? { "ufw " + args } else { "ufw --force delete " + args }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
