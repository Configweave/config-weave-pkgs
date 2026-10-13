use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // leave the group's instance usable for the tests after this one
    shell::bash("zypper -q rr cw-broken", Value::Null)?
    if fs::exists("/var/lib/config-weave/zypper-cache-updated") { return Err("a failed refresh was recorded as fresh") }
    Ok(true)
}
