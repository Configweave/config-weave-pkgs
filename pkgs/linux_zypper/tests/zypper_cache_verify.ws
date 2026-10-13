use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let ok = shell::bash("test -z \"$(find /etc/zypp/repos.d -newer /var/lib/config-weave/zypper-cache-updated | head -n 1)\"", Value::Null)?
    if !fs::is_file("/var/lib/config-weave/zypper-cache-updated") || !ok.success { return Err("the stamp is missing or older than /etc/zypp/repos.d") }
    // zypper refresh really ran: the local repository's metadata is cached
    if !fs::is_dir("/var/cache/zypp/raw/cw-plain") { return Err("cw-plain was not refreshed") }
    Ok(true)
}
