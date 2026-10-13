use value
use common
use fs
use shell

fn require_ufw() -> Result[unit, string] {
    if fs::exists("/usr/sbin/ufw") || fs::exists("/usr/bin/ufw") { return Ok(()) }
    Err("ufw not found; is it installed?")
}

// "22", "22/tcp", "6000:6007/tcp", "80,443/tcp": anything starting with a
// digit is a port spec; anything else names an application profile.
fn is_port_spec(port: string) -> bool {
    for c in port.chars() { return c >= '0' && c <= '9' }
    false
}

fn valid_port(port: string) -> Result[unit, string] {
    if port == "" { return Err("missing 'port' parameter") }
    common::one_line("port", port)?
    if is_port_spec(port) {
        for c in port.chars() {
            let ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || c == ':' || c == ',' || c == '/'
            if !ok { return Err("invalid 'port' value '" + port + "' (expected a port spec such as 22/tcp or an application profile name)") }
        }
        return Ok(())
    }
    if port.starts_with("-") || port.contains("'") || port.contains("\"") || port.contains("\\") {
        return Err("invalid application profile name '" + port + "'")
    }
    Ok(())
}

fn valid_from(from: string) -> Result[unit, string] {
    common::one_line("from", from)?
    for c in from.chars() {
        let ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '.' || c == ':' || c == '/'
        if !ok { return Err("invalid 'from' value '" + from + "' (expected an address, a CIDR or any)") }
    }
    Ok(())
}

// The rule as two parallel token lists: `shown` is how `ufw show added`
// prints it (an application name with a space is single-quoted there),
// `argv` the same tokens shell-quoted for the command line.
fn rule_tokens(params: Value) -> Result[List[List[string]], string] {
    let action = common::param_str(params, "action", "allow")
    if action != "allow" && action != "deny" && action != "reject" && action != "limit" {
        return Err("invalid 'action' value '" + action + "' (expected :allow, :deny, :reject or :limit)")
    }
    let port = common::param_str(params, "port", "")
    valid_port(port)?
    // "any" is ufw's own spelling of no source
    let from = common::param_str(params, "from", "")
    if from == "any" { from = "" }
    valid_from(from)?
    let shown = [action]
    let argv = [action]
    if from != "" {
        shown.push("from")
        shown.push(from)
        shown.push("to")
        shown.push("any")
        argv.push("from")
        argv.push(common::q(from))
        argv.push("to")
        argv.push("any")
    }
    if is_port_spec(port) {
        if from == "" {
            shown.push(port)
            argv.push(common::q(port))
        } else {
            // "22/tcp" splits into a port + proto clause once a source is set
            let parts = port.split("/")
            let portnum = parts.get(0).unwrap_or(port)
            let proto = parts.get(1).unwrap_or("")
            shown.push("port")
            shown.push(portnum)
            argv.push("port")
            argv.push(common::q(portnum))
            if proto != "" {
                shown.push("proto")
                shown.push(proto)
                argv.push("proto")
                argv.push(common::q(proto))
            }
        }
    } else {
        if from != "" {
            shown.push("app")
            argv.push("app")
        }
        shown.push(if common::has_space(port) { "'" + port + "'" } else { port })
        argv.push(common::q(port))
    }
    Ok([shown, argv])
}

// `ufw show added` lists recorded rules as "ufw <args>" lines and works even
// while the firewall is inactive — unlike `ufw status`, which hides them.
fn rule_recorded(shown: string) -> Result[bool, string] {
    let out = common::run("ufw show added", "ufw show added")?
    for line in out.stdout.split("\n") {
        if line.trim() == "ufw " + shown { return Ok(true) }
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_ufw()?
    let toks = rule_tokens(params)?
    let recorded = rule_recorded(toks.get(0).unwrap_or([]).join(" "))?
    if recorded == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_ufw()?
    let toks = rule_tokens(params)?
    let args = toks.get(1).unwrap_or([]).join(" ")
    if common::want_present(params)? {
        common::run("ufw " + args, "ufw " + args)?
    } else {
        common::run("ufw delete " + args, "ufw --force delete " + args)?
    }
    Ok(ApplyResult::Success)
}
