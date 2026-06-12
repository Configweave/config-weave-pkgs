use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn check(params: Value) -> Result[CheckResult, string] {
    let content = param_str(params, "content", "")
    if fs::is_file("/etc/nftables.conf") && fs::read("/etc/nftables.conf")? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    fs::write("/etc/nftables.conf", param_str(params, "content", ""))?
    if param_bool(params, "reload", false) {
        if !(fs::exists("/usr/sbin/nft") || fs::exists("/usr/bin/nft") || fs::exists("/sbin/nft")) {
            return Err("nft command is not available")
        }
        let out = shell::run("nft -f /etc/nftables.conf", Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}

