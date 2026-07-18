use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn require_nft() -> Result[unit, string] {
    if fs::exists("/usr/sbin/nft") || fs::exists("/usr/bin/nft") || fs::exists("/sbin/nft") { return Ok(()) }
    Err("nft not found; is nftables installed?")
}

// Lines of `nft -a list chain` look like "tcp dport 22 accept # handle 4".
// Write the rule exactly as nft prints it or the comparison will not match.
fn find_handle(family: string, table: string, chain: string, rule: string) -> Result[string, string] {
    let out = shell::bash("nft -a list chain " + q(family) + " " + q(table) + " " + q(chain), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    for line in out.stdout.split("\n") {
        let t = line.trim()
        if !t.starts_with(rule) { continue }
        let rest = t.slice(rule.len(), t.len()).trim()
        if rest == "" { return Ok("") }
        if rest.starts_with("# handle ") {
            return Ok(rest.slice("# handle ".len(), rest.len()).trim())
        }
    }
    Err("__not_found__")
}

fn rule_present(family: string, table: string, chain: string, rule: string) -> Result[bool, string] {
    let found = find_handle(family, table, chain, rule)
    if let Err(e) = found {
        if e == "__not_found__" { return Ok(false) }
        return Err(e)
    }
    Ok(true)
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_nft()?
    let table = param_str(params, "table", "")
    let chain = param_str(params, "chain", "")
    let rule = param_str(params, "rule", "")
    if table == "" { return Err("missing 'table' parameter") }
    if chain == "" { return Err("missing 'chain' parameter") }
    if rule == "" { return Err("missing 'rule' parameter") }
    let family = param_str(params, "family", "inet")
    if !want_present(params)? {
        // a missing chain (or table) means the rule is gone too
        let probe = shell::bash("nft list chain " + q(family) + " " + q(table) + " " + q(chain) + " 2>/dev/null", Value::Null)?
        if !probe.success { return Ok(CheckResult::AlreadyConfigured) }
        if rule_present(family, table, chain, rule)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if rule_present(family, table, chain, rule)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_nft()?
    let table = param_str(params, "table", "")
    let chain = param_str(params, "chain", "")
    let rule = param_str(params, "rule", "")
    if table == "" { return Err("missing 'table' parameter") }
    if chain == "" { return Err("missing 'chain' parameter") }
    if rule == "" { return Err("missing 'rule' parameter") }
    let family = param_str(params, "family", "inet")
    if !want_present(params)? {
        let probe = shell::bash("nft list chain " + q(family) + " " + q(table) + " " + q(chain) + " 2>/dev/null", Value::Null)?
        if !probe.success { return Ok(ApplyResult::Success) }
        let handle = find_handle(family, table, chain, rule)
        if let Err(e) = handle {
            if e == "__not_found__" { return Ok(ApplyResult::Success) }
            return Err(e)
        }
        let h = handle.unwrap_or("")
        if h == "" { return Err("rule found but nft reported no handle; cannot delete it") }
        let out = shell::bash("nft delete rule " + q(family) + " " + q(table) + " " + q(chain) + " handle " + h, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    if rule_present(family, table, chain, rule)? { return Ok(ApplyResult::Success) }
    let out = shell::bash("nft add rule " + q(family) + " " + q(table) + " " + q(chain) + " " + rule, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
