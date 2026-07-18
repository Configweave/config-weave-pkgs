use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
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

fn chain_exists(family: string, table: string, name: string) -> Result[bool, string] {
    let out = shell::bash("nft list chain " + q(family) + " " + q(table) + " " + q(name) + " 2>/dev/null", Value::Null)?
    Ok(out.success)
}

// Base-chain spec: "{ type filter hook input priority 0; policy drop; }".
// Empty when type/hook are unset (a regular chain).
fn base_spec(params: Value) -> Result[string, string] {
    let kind = param_str(params, "type", "")
    let hook = param_str(params, "hook", "")
    if kind == "" && hook == "" { return Ok("") }
    if kind == "" || hook == "" { return Err("'type' and 'hook' must be set together for a base chain") }
    let policy = param_str(params, "policy", "")
    let policy_clause = if policy != "" { " policy " + policy + ";" } else { "" }
    Ok(" '{{ type " + kind + " hook " + hook + " priority " + str(param_int(params, "priority", 0)) + ";" + policy_clause + " }}'")
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_nft()?
    let table = param_str(params, "table", "")
    let name = param_str(params, "name", "")
    if table == "" { return Err("missing 'table' parameter") }
    if name == "" { return Err("missing 'name' parameter") }
    let exists = chain_exists(param_str(params, "family", "inet"), table, name)?
    if exists == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_nft()?
    let table = param_str(params, "table", "")
    let name = param_str(params, "name", "")
    if table == "" { return Err("missing 'table' parameter") }
    if name == "" { return Err("missing 'name' parameter") }
    let family = param_str(params, "family", "inet")
    let ident = q(family) + " " + q(table) + " " + q(name)
    if !want_present(params)? {
        let out = shell::bash("nft delete chain " + ident, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }
    let out = shell::bash("nft add chain " + ident + base_spec(params)?, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
