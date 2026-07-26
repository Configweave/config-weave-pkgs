use value

fn str_at(facts: Value, gather: string, key: string) -> string {
    if let Some(g) = facts.get(gather) {
        if let Some(v) = g.get(key) {
            if let Some(s) = v.as_string() { return s }
        }
    }
    ""
}

fn list_at(facts: Value, gather: string, key: string) -> Option[List[Value]] {
    if let Some(g) = facts.get(gather) {
        if let Some(v) = g.get(key) {
            return v.as_list()
        }
    }
    None
}

// The container run can only prove these gatherers degrade gracefully. On a
// real booted system they must return substance: running units, a routable
// interface, and a real root filesystem.
fn verify(facts: Value) -> Result[bool, string] {
    let services = if let Some(l) = list_at(facts, "svc", "services") { l } else {
        return Err("services did not return a list")
    }
    if services.is_empty() { return Err("services returned nothing on a systemd host") }
    let active = [false]
    for s in services {
        if let Some(a) = s.get("active") {
            if a.as_string().unwrap_or("") == "active" { active.set(0, true) }
        }
    }
    if !active.get(0).unwrap_or(false) { return Err("no service reported as active") }

    let ifaces = if let Some(l) = list_at(facts, "net", "interfaces") { l } else {
        return Err("network returned no interfaces list")
    }
    let non_loopback = [false]
    for i in ifaces {
        if let Some(n) = i.get("name") {
            if n.as_string().unwrap_or("") != "lo" { non_loopback.set(0, true) }
        }
    }
    if !non_loopback.get(0).unwrap_or(false) { return Err("only loopback was enumerated") }

    let mounts = if let Some(l) = list_at(facts, "mnt", "mounts") { l } else {
        return Err("mounts did not return a list")
    }
    let has_root = [false]
    for m in mounts {
        if let Some(p) = m.get("mountpoint") {
            if p.as_string().unwrap_or("") == "/" { has_root.set(0, true) }
        }
    }
    if !has_root.get(0).unwrap_or(false) { return Err("no root filesystem in mounts") }

    if str_at(facts, "net", "network_system") == "unknown" {
        return Err("network_system stayed unknown on a real system")
    }
    Ok(true)
}
