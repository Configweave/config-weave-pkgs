use value
use common
use fs
use shell

// firewall-cmd talks to the daemon over D-Bus, for --permanent too, so
// firewalld must be running.
fn require_firewalld() -> Result[unit, string] {
    if !fs::exists("/usr/bin/firewall-cmd") && !fs::exists("/bin/firewall-cmd") {
        return Err("firewall-cmd not found; is firewalld installed?")
    }
    let out = shell::bash("firewall-cmd --state", Value::Null)?
    if !out.success { return Err(common::cmd_err("firewall-cmd --state", out) + "; start the firewalld service first") }
    Ok(())
}

fn zone_arg(params: Value) -> Result[string, string] {
    let zone = common::param_str(params, "zone", "")
    if zone == "" { return Ok("") }
    common::token("zone", zone)?
    if zone.starts_with("-") { return Err("invalid 'zone' value '" + zone + "'") }
    Ok(" --zone=" + common::q(zone))
}

// The rule kind is whichever single selector param is set: [kind, value].
fn selector(params: Value) -> Result[List[string], string] {
    let kinds = []
    for k in ["service", "port", "source", "rich_rule"] {
        let v = common::param_str(params, k, "")
        if v == "" { continue }
        if k == "rich_rule" { common::one_line(k, v)? } else { common::token(k, v)? }
        if v.starts_with("-") { return Err("invalid '" + k + "' value '" + v + "'") }
        kinds.push([k.replace("_", "-"), v])
    }
    if kinds.len() != 1 {
        return Err("exactly one of 'service', 'port', 'source' or 'rich_rule' must be set")
    }
    Ok(kinds.get(0).unwrap_or([]))
}

// The configurations the rule is managed in: the running firewall always,
// and the saved one too when permanent = true.
fn configs(params: Value) -> List[string] {
    if common::param_bool(params, "permanent", true) { ["", " --permanent"] } else { [""] }
}

// --query-* exits 0 when the rule is there and 1 when it is not; anything
// else (an unknown zone or service, a malformed rich rule) is an error.
fn query(cfg: string, zone: string, kind: string, val: string) -> Result[bool, string] {
    let cmd = "firewall-cmd" + cfg + zone + " --query-" + kind + "=" + common::q(val)
    let out = shell::bash(cmd, Value::Null)?
    if out.code == 0 { return Ok(true) }
    if out.code == 1 { return Ok(false) }
    Err(common::cmd_err(cmd, out))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let sel = selector(params)?
    let zone = zone_arg(params)?
    let want = common::want_present(params)?
    require_firewalld()?
    for cfg in configs(params) {
        if query(cfg, zone, sel.get(0).unwrap_or(""), sel.get(1).unwrap_or(""))? != want { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let sel = selector(params)?
    let zone = zone_arg(params)?
    let want = common::want_present(params)?
    require_firewalld()?
    let kind = sel.get(0).unwrap_or("")
    let val = sel.get(1).unwrap_or("")
    let verb = if want { " --add-" } else { " --remove-" }
    for cfg in configs(params) {
        if query(cfg, zone, kind, val)? == want { continue }
        let out = common::run("firewall-cmd" + cfg + verb + kind, "firewall-cmd" + cfg + zone + verb + kind + "=" + common::q(val))?
    }
    Ok(ApplyResult::Success)
}
