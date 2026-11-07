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

// Test services_no_manager: no manager is complete, so no services.
fn verify(facts: Value) -> Result[bool, string] {
    let svc = services(facts)?
    if !svc.is_empty() { return Err("expected no services, got " + show(svc.get(0).unwrap_or(Value::Null)) + " and " + str(svc.len() - 1) + " more") }
    Ok(true)
}
