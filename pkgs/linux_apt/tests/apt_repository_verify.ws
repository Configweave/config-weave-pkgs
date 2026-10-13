use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let d = "/etc/apt/sources.list.d/"
    if fs::read(d + "config-weave-test.list")? != "deb http://deb.debian.org/debian bookworm main\n" { return Err("config-weave-test.list still drifted") }
    if !fs::read(d + "cw-deb822.sources")?.starts_with("Types: deb\nURIs: http://deb.debian.org/debian\n") { return Err("cw-deb822.sources not written") }
    if !fs::read(d + "cw-switch.sources")?.contains("bookworm-updates") { return Err("cw-switch.sources not written") }
    if fs::exists(d + "cw-switch.list") { return Err("cw-switch.list should be gone after the switch") }
    if fs::exists(d + "cw-stale.list") || fs::exists(d + "cw-stale.sources") { return Err("cw-stale should be gone in both formats") }
    if fs::exists("/etc/cw-evil.list") || fs::exists("/etc/apt/cw-evil.list") { return Err("a traversal name wrote outside sources.list.d") }
    // apt itself accepts every file written here
    let ok = shell::bash("apt-get indextargets >/dev/null", Value::Null)?
    if !ok.success { return Err("apt rejects the sources: " + ok.stderr.trim()) }
    Ok(true)
}
