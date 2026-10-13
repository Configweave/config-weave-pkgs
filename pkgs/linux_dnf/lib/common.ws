use value
use fs
use shell

// Helpers shared by linux_dnf's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// The dnf-family front-end actually present on this host, newest first.
fn dnf_bin() -> Result[string, string] {
    if fs::exists("/usr/bin/dnf5") { return Ok("dnf5") }
    if fs::exists("/usr/bin/dnf") { return Ok("dnf") }
    if fs::exists("/usr/bin/microdnf") { return Ok("microdnf") }
    if fs::exists("/usr/bin/yum") { return Ok("yum") }
    Err("no dnf-family package manager found (dnf5, dnf, microdnf or yum)")
}

// The front-end for versionlock. Deliberately not dnf_bin(): versionlock is
// a plugin for dnf5, dnf and yum, and microdnf has no equivalent, so a
// microdnf-only host is an error here rather than a fallback.
fn lock_bin() -> Result[string, string] {
    if fs::exists("/usr/bin/dnf5") { return Ok("dnf5") }
    if fs::exists("/usr/bin/dnf") { return Ok("dnf") }
    if fs::exists("/usr/bin/yum") { return Ok("yum") }
    Err("hold requires dnf5, dnf or yum with the versionlock plugin")
}
