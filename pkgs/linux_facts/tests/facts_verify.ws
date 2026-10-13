use value

fn str_at(facts: Value, gather: string, key: string) -> string {
    if let Some(g) = facts.get(gather) {
        if let Some(v) = g.get(key) {
            if let Some(s) = v.as_string() { return s }
        }
    }
    ""
}

fn int_at(facts: Value, gather: string, key: string) -> int {
    if let Some(g) = facts.get(gather) {
        if let Some(v) = g.get(key) {
            if let Some(i) = v.as_int() { return i }
        }
    }
    0
}

fn list_at(facts: Value, gather: string, key: string) -> Option[List[Value]] {
    if let Some(g) = facts.get(gather) {
        if let Some(v) = g.get(key) {
            return v.as_list()
        }
    }
    None
}

fn field(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { v.as_string().unwrap_or("") } else { "" }
}

// Shared by the Debian and Alpine container tests: every gatherer returns
// populated fields, not just the right shape.
fn verify(facts: Value) -> Result[bool, string] {
    if str_at(facts, "os", "kernel") == "" { return Err("os_release returned no kernel") }
    if str_at(facts, "os", "arch") == "" { return Err("os_release returned no arch") }
    if str_at(facts, "init", "init") == "" { return Err("init_system returned no init") }
    if str_at(facts, "net", "network_system") == "" { return Err("network returned no network_system") }

    let mounts = if let Some(l) = list_at(facts, "mnt", "mounts") { l } else { return Err("mounts returned no list") }
    if mounts.is_empty() || int_at(facts, "mnt", "count") != mounts.len() { return Err("mounts count does not match its list") }
    for m in mounts {
        for k in ["spec", "mountpoint", "fstype", "options"] {
            if field(m, k) == "" { return Err("a mount has an empty " + k) }
        }
        if field(m, "mountpoint").contains("\\040") { return Err("a mount point was not unescaped: " + field(m, "mountpoint")) }
    }
    if str_at(facts, "os", "id") == "debian" {
        if !mounts.any(|m| field(m, "mountpoint") == "/mnt/cw space" && field(m, "fstype") == "tmpfs") {
            return Err("the mount at '/mnt/cw space' is missing or still escaped")
        }
    }

    let ifaces = if let Some(l) = list_at(facts, "net", "interfaces") { l } else { return Err("network returned no interfaces list") }
    let lo = ifaces.find(|i| field(i, "name") == "lo")
    if lo.is_none() { return Err("loopback interface not enumerated") }
    for i in ifaces {
        if field(i, "name") == "" || field(i, "state") == "" { return Err("an interface has an empty name or state") }
        if field(i, "name") != "lo" && field(i, "mac") == "" { return Err("interface " + field(i, "name") + " has no mac") }
    }

    if list_at(facts, "svc", "services").is_none() { return Err("services did not return a list") }
    Ok(true)
}
