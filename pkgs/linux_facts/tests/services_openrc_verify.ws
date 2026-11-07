use value

fn field(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { v.as_string().unwrap_or("") } else { "" }
}

fn services(facts: Value) -> Result[List[Value], string] {
    if let Some(g) = facts.get("svc") {
        if let Some(v) = g.get("services") {
            if let Some(l) = v.as_list() { return Ok(l) }
        }
    }
    Err("services did not return a list")
}

fn show(m: Value) -> string {
    field(m, "name") + " (active=" + field(m, "active") + " sub=" + field(m, "sub") + " enabled=" + field(m, "enabled") + ")"
}

// Every entry is complete, enabled is enabled or disabled, and no name
// repeats.
fn well_formed(svc: List[Value]) -> Result[unit, string] {
    let seen: Map[string, bool] = #{}
    for s in svc {
        for k in ["name", "active", "sub", "enabled"] {
            if field(s, k) == "" { return Err("an entry has an empty " + k + ": " + show(s)) }
        }
        let en = field(s, "enabled")
        if en != "enabled" && en != "disabled" { return Err("enabled is not enabled or disabled: " + show(s)) }
        if seen.contains_key(field(s, "name")) { return Err("service listed twice: " + field(s, "name")) }
        seen.insert(field(s, "name"), true)
    }
    Ok(())
}

fn expect_entry(svc: List[Value], name: string, active: string, sub: string, enabled: string) -> Result[unit, string] {
    let want = name + " (active=" + active + " sub=" + sub + " enabled=" + enabled + ")"
    if let Some(s) = svc.find(|s| field(s, "name") == name) {
        if show(s) != want { return Err("want " + want + ", got " + show(s)) }
        return Ok(())
    }
    Err("service missing: " + want)
}

// The seeded services are cw-*: exactly the expected ones are listed.
fn only_seeded(svc: List[Value], names: List[string]) -> Result[unit, string] {
    for s in svc {
        let n = field(s, "name")
        if n.starts_with("cw-") && !names.contains(n) { return Err("unexpected seeded service: " + show(s)) }
    }
    Ok(())
}

// Seeded by test services_openrc.
fn verify(facts: Value) -> Result[bool, string] {
    let svc = services(facts)?
    well_formed(svc)?
    expect_entry(svc, "cw-run", "active", "started", "enabled")?
    expect_entry(svc, "cw-stop", "inactive", "stopped", "enabled")?
    expect_entry(svc, "cw-off", "inactive", "stopped", "disabled")?
    expect_entry(svc, "cw-crash", "failed", "crashed", "disabled")?
    only_seeded(svc, ["cw-run", "cw-stop", "cw-off", "cw-crash"])?
    Ok(true)
}
