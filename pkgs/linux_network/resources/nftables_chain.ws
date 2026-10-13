use value
use common
use fs
use shell

fn chain_exists(family: string, table: string, name: string) -> Result[bool, string] {
    let out = shell::bash("nft list chain " + common::q(family) + " " + common::q(table) + " " + common::q(name) + " 2>/dev/null", Value::Null)?
    Ok(out.success)
}

// Base-chain spec: "{ type filter hook input priority 0; policy drop; }".
// Empty when type/hook are unset (a regular chain).
fn base_spec(params: Value) -> Result[string, string] {
    let kind = common::param_str(params, "type", "")
    let hook = common::param_str(params, "hook", "")
    if kind == "" && hook == "" { return Ok("") }
    if kind == "" || hook == "" { return Err("'type' and 'hook' must be set together for a base chain") }
    let policy = common::param_str(params, "policy", "")
    let policy_clause = if policy != "" { " policy " + policy + ";" } else { "" }
    Ok(" '{{ type " + kind + " hook " + hook + " priority " + str(common::param_int(params, "priority", 0)) + ";" + policy_clause + " }}'")
}

fn check(params: Value) -> Result[CheckResult, string] {
    common::require_nft()?
    let table = common::param_str(params, "table", "")
    let name = common::param_str(params, "name", "")
    if table == "" { return Err("missing 'table' parameter") }
    if name == "" { return Err("missing 'name' parameter") }
    let exists = chain_exists(common::param_str(params, "family", "inet"), table, name)?
    if exists == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_nft()?
    let table = common::param_str(params, "table", "")
    let name = common::param_str(params, "name", "")
    if table == "" { return Err("missing 'table' parameter") }
    if name == "" { return Err("missing 'name' parameter") }
    let family = common::param_str(params, "family", "inet")
    let ident = common::q(family) + " " + common::q(table) + " " + common::q(name)
    if !common::want_present(params)? {
        let out = shell::bash("nft delete chain " + ident, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    let out = shell::bash("nft add chain " + ident + base_spec(params)?, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
