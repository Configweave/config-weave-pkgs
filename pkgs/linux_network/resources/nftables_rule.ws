use value
use common
use fs
use shell

// Lines of `nft -a list chain` look like "tcp dport 22 accept # handle 4".
// Write the rule exactly as nft prints it or the comparison will not match.
fn find_handle(family: string, table: string, chain: string, rule: string) -> Result[string, string] {
    let out = shell::bash("nft -a list chain " + common::q(family) + " " + common::q(table) + " " + common::q(chain), Value::Null)?
    // No such table or chain — then the rule is not in it either. This is the
    // normal case during a check run, where the step that creates the chain
    // has not applied yet, so it must not be an error.
    if !out.success { return Err("__not_found__") }
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
    common::require_nft()?
    let table = common::param_str(params, "table", "")
    let chain = common::param_str(params, "chain", "")
    let rule = common::param_str(params, "rule", "")
    if table == "" { return Err("missing 'table' parameter") }
    if chain == "" { return Err("missing 'chain' parameter") }
    if rule == "" { return Err("missing 'rule' parameter") }
    let family = common::param_str(params, "family", "inet")
    // A missing chain (or table) reads as "rule not present", which is
    // already what :absent wants and what :present has to converge to.
    if !common::want_present(params)? {
        if rule_present(family, table, chain, rule)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if rule_present(family, table, chain, rule)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_nft()?
    let table = common::param_str(params, "table", "")
    let chain = common::param_str(params, "chain", "")
    let rule = common::param_str(params, "rule", "")
    if table == "" { return Err("missing 'table' parameter") }
    if chain == "" { return Err("missing 'chain' parameter") }
    if rule == "" { return Err("missing 'rule' parameter") }
    let family = common::param_str(params, "family", "inet")
    if !common::want_present(params)? {
        let probe = shell::bash("nft list chain " + common::q(family) + " " + common::q(table) + " " + common::q(chain) + " 2>/dev/null", Value::Null)?
        if !probe.success { return Ok(ApplyResult::Success) }
        let handle = find_handle(family, table, chain, rule)
        if let Err(e) = handle {
            if e == "__not_found__" { return Ok(ApplyResult::Success) }
            return Err(e)
        }
        let h = handle.unwrap_or("")
        if h == "" { return Err("rule found but nft reported no handle; cannot delete it") }
        let out = shell::bash("nft delete rule " + common::q(family) + " " + common::q(table) + " " + common::q(chain) + " handle " + h, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    if rule_present(family, table, chain, rule)? { return Ok(ApplyResult::Success) }
    let out = shell::bash("nft add rule " + common::q(family) + " " + common::q(table) + " " + common::q(chain) + " " + rule, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
