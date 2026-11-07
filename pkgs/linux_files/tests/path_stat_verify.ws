use value

// The uid or gid that the gatherer reported for one path.
fn id_at(facts: Value, gather: string, key: string) -> Result[int, string] {
    let g = if let Some(v) = facts.get(gather) { v } else { return Err(gather + " was not gathered") }
    if let Some(v) = g.get(key) {
        if let Some(i) = v.as_int() { return Ok(i) }
    }
    Err(gather + " has no " + key)
}

fn owned(facts: Value, gather: string, uid: int, gid: int) -> Result[unit, string] {
    let got_uid = id_at(facts, gather, "uid")?
    let got_gid = id_at(facts, gather, "gid")?
    if got_uid != uid || got_gid != gid { return Err(gather + ": owner is not the seeded uid:gid") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    owned(facts, "own_file", 3001, 3002)?
    owned(facts, "own_dir", 3003, 3004)?
    // the link's own owner, not the target's (3007:3008)
    owned(facts, "own_link", 3005, 3006)?
    owned(facts, "own_target", 3007, 3008)?
    owned(facts, "own_dangling", 3009, 3009)?
    let m = if let Some(v) = facts.get("own_missing") { v } else { return Err("own_missing was not gathered") }
    if let Some(_) = m.get("uid") { return Err("a missing path reported a uid") }
    if let Some(_) = m.get("gid") { return Err("a missing path reported a gid") }
    Ok(true)
}
