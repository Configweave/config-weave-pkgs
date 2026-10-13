use value
use common
use fs
use hash

// One drop-in per option and host pattern. The all-hosts file is
// <key>.conf; any other pattern adds a readable form of it and a digest
// (so `a*` and `a?` stay apart). A host-specific file sorts before the
// all-hosts one ('-' < '.'), so its value wins, as ssh_config expects
// specific blocks first.
fn conf_path(key: string, host: string) -> string {
    let base = "/etc/ssh/ssh_config.d/" + common::dropin_prefix() + key.to_lower()
    if host == "*" { return base + ".conf" }
    let safe = ""
    for c in host.chars() {
        let t = str(c)
        let ok = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-".contains(t)
        safe = safe + (if ok { t } else { "_" })
    }
    base + "-" + safe.slice(0, 40) + "-" + hash::sha256(host).slice(0, 8) + ".conf"
}

// Before 10-, the drop-in was 50-config-weave-<key>.conf whatever the host.
fn legacy_path(key: string) -> string {
    "/etc/ssh/ssh_config.d/50-config-weave-" + key.to_lower() + ".conf"
}

fn host(params: Value) -> string { common::param_str(params, "host", "*").trim() }

fn desired(params: Value) -> Result[string, string] {
    let key = common::param_str(params, "key", "")
    let value = common::param_str(params, "value", "").trim()
    if value == "" { return Err("missing 'value' parameter") }
    Ok("Host " + host(params) + "\n    " + key + " " + value + "\n")
}

fn validate(params: Value) -> Result[unit, string] {
    common::valid_option_key(common::param_str(params, "key", ""), ["host", "match", "include"])?
    common::one_line("value", common::param_str(params, "value", ""))?
    common::one_line("host", common::param_str(params, "host", "*"))?
    if host(params) == "" { return Err("'host' must not be empty") }
    if common::want_present(params)? { let d = desired(params)? }
    Ok(())
}

// The old file belongs to this step only when it is for the same host.
fn legacy_is_ours(params: Value) -> bool {
    let p = legacy_path(common::param_str(params, "key", ""))
    if !fs::is_file(p) { return false }
    if let Ok(t) = fs::read(p) { return t.starts_with("Host " + host(params) + "\n") }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let p = conf_path(common::param_str(params, "key", ""), host(params))
    if legacy_is_ours(params) { return Ok(CheckResult::NotConfigured) }
    if !common::want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if let Ok(t) = fs::read(p) { if t == desired(params)? { return Ok(CheckResult::AlreadyConfigured) } }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let key = common::param_str(params, "key", "")
    let p = conf_path(key, host(params))
    if legacy_is_ours(params) { fs::delete(legacy_path(key))? }
    if !common::want_present(params)? {
        if fs::is_file(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    fs::mkdir("/etc/ssh/ssh_config.d")?
    fs::write(p, desired(params)?)?
    Ok(ApplyResult::Success)
}
