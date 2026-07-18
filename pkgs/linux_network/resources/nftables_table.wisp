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

fn table_exists(family: string, name: string) -> Result[bool, string] {
    let out = shell::bash("nft list table " + q(family) + " " + q(name) + " 2>/dev/null", Value::Null)?
    Ok(out.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_nft()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let exists = table_exists(param_str(params, "family", "inet"), name)?
    if exists == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_nft()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let family = param_str(params, "family", "inet")
    let verb = if want_present(params)? { "add" } else { "delete" }
    let out = shell::bash("nft " + verb + " table " + q(family) + " " + q(name), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
