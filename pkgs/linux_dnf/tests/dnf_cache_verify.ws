use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let stamp = shell::bash("test /var/lib/config-weave/dnf-cache-updated-dnf5 -nt /tmp/cw-before-refresh", Value::Null)?
    if !stamp.success { return Err("the dnf5 stamp was not rewritten") }
    // makecache --refresh really went to the repositories: their cache
    // attributes changed, which a plain makecache inside metadata_expire
    // leaves alone.
    let out = shell::bash("find /var/cache/libdnf5 -maxdepth 2 -name attrs -newer /tmp/cw-before-refresh | head -n 1", Value::Null)?
    if out.stdout.trim() == "" { return Err("no repository metadata was refreshed") }
    Ok(true)
}
