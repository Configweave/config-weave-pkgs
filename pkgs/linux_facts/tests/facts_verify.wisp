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

fn verify(facts: Value) -> Result[bool, string] {
    if str_at(facts, "init", "init") == "" { return Err("init_system returned no init") }
    if int_at(facts, "mnt", "count") <= 0 { return Err("mounts returned no entries") }
    if str_at(facts, "net", "network_system") == "" { return Err("network returned no network_system") }

    let ifaces = if let Some(l) = list_at(facts, "net", "interfaces") { l } else {
        return Err("network returned no interfaces list")
    }
    if ifaces.is_empty() { return Err("network enumerated no interfaces") }
    let has_lo = [false]
    for i in ifaces {
        if let Some(n) = i.get("name") {
            if n.as_string().unwrap_or("") == "lo" { has_lo.set(0, true) }
        }
    }
    if !has_lo.get(0).unwrap_or(false) { return Err("loopback interface not enumerated") }

    if list_at(facts, "svc", "services").is_none() { return Err("services did not return a list") }
    Ok(true)
}
