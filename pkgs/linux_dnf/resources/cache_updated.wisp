use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn dnf_bin() -> Result[string, string] {
    if fs::exists("/usr/bin/dnf5") { return Ok("dnf5") }
    if fs::exists("/usr/bin/dnf") { return Ok("dnf") }
    if fs::exists("/usr/bin/microdnf") { return Ok("microdnf") }
    if fs::exists("/usr/bin/yum") { return Ok("yum") }
    Err("no dnf-family package manager found (dnf5, dnf, microdnf or yum)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let marker = param_str(params, "marker", "/var/lib/config-weave/package-cache-updated")
    if fs::exists(marker) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let bin = dnf_bin()?
    // microdnf has no -y for makecache
    let cmd = if bin == "microdnf" { "microdnf makecache" } else { bin + " makecache -y" }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let marker = param_str(params, "marker", "/var/lib/config-weave/package-cache-updated")
    fs::mkdir(path::parent(marker))?
    fs::write(marker, bin + "\n")?
    Ok(ApplyResult::Success)
}
