use value
use fs
use path
use log
use common

// One drop-in per key. Both separators become "-" in the file name: a key
// may be written with "/" (net/ipv4/conf/eth0.100/forwarding, the only
// spelling for an interface whose name has a dot), and a raw "/" would
// turn the name into a path.
fn dropin_path(key: string) -> string {
    "/etc/sysctl.d/99-config-weave-" + key.replace("/", "-").replace(".", "-") + ".conf"
}

fn validate_key(key: string) -> Result[unit, string] {
    if key == "" { return Err("missing 'key' parameter") }
    if common::has_space(key) || key.contains("=") || key.starts_with("-") || key.starts_with("/") || key.starts_with(".") {
        return Err("invalid sysctl key '" + key + "'")
    }
    for seg in key.split("/") { if seg == ".." { return Err("invalid sysctl key '" + key + "'") } }
    common::one_line("key", key)
}

// Multi-value keys (net.ipv4.ip_local_port_range) come back from sysctl
// tab-separated; compare whitespace-split fields, so "32768 60999" matches.
fn words(v: string) -> List[string] {
    v.trim().replace("\t", " ").replace("\n", " ").split(" ").filter(|w| w != "")
}

fn dropin_text(key: string, want: string) -> string { key + " = " + words(want).join(" ") + "\n" }

fn check(params: Value) -> Result[CheckResult, string] {
    let key = common::param_str(params, "key", "")
    validate_key(key)?
    let p = dropin_path(key)
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = common::param_str(params, "value", "")
    common::one_line("value", want)?
    if words(want).is_empty() { return Err("missing 'value' parameter (required when ensure is :present)") }
    let out = common::output("sysctl -n " + key, "sysctl -n -- " + common::q(key))?
    if words(out.stdout) != words(want) { return Ok(CheckResult::NotConfigured) }
    if !fs::is_file(p) || fs::read(p).unwrap_or("") != dropin_text(key, want) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = common::param_str(params, "key", "")
    validate_key(key)?
    let p = dropin_path(key)
    if !common::want_present(params)? {
        // The running value is left as it is: there is no record of what
        // it was before, and it resets at the next boot anyway.
        if fs::exists(p) {
            log::info("deleting " + p)
            fs::delete(p)?
        }
        return Ok(ApplyResult::Success)
    }
    let want = common::param_str(params, "value", "")
    common::one_line("value", want)?
    if words(want).is_empty() { return Err("missing 'value' parameter (required when ensure is :present)") }
    common::run("sysctl -w " + key, "sysctl -w -- " + common::q(key + "=" + words(want).join(" ")))?
    fs::mkdir(path::parent(p))?
    common::write_atomic(p, dropin_text(key, want))?
    Ok(ApplyResult::Success)
}
