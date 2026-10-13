use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // The stamp was rewritten by the refresh, after every source file.
    let newer = shell::bash("test -f /var/lib/config-weave/apt-cache-updated && test -z \"$(find /etc/apt/sources.list.d -newer /var/lib/config-weave/apt-cache-updated -print | head -n 1)\"", Value::Null)?
    if !newer.success { return Err("the stamp is missing or older than /etc/apt/sources.list.d") }
    // apt-get update really ran: the index lists exist.
    let lists = shell::bash("ls /var/lib/apt/lists/ | grep -q _Packages", Value::Null)?
    if !lists.success { return Err("no Packages lists under /var/lib/apt/lists") }
    Ok(true)
}
