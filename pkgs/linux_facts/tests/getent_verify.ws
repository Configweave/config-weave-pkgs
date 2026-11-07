use value
use env
use fs
use getent_common

// Shared by getent_gathers and getent_errors. The expect blocks assert
// database, key, found and count; this script asserts the records.

fn rows(facts: Value, label: string) -> Result[List[List[string]], string] {
    let Some(g) = facts.get(label) else { return Err("gather '" + label + "' is missing") }
    let Some(v) = g.get("entries") else { return Err(label + ": no entries") }
    let Some(list) = v.as_list() else { return Err(label + ": entries is not a list") }
    let Some(c) = g.get("count") else { return Err(label + ": no count") }
    if c.as_int().unwrap_or(-1) != list.len() { return Err(label + ": count does not match the entries") }
    let out = []
    for e in list {
        let Some(fv) = e.get("fields") else { return Err(label + ": an entry has no fields") }
        let Some(fl) = fv.as_list() else { return Err(label + ": fields is not a list") }
        let r = []
        for f in fl { r.push(f.as_string().unwrap_or("<not a string>")) }
        out.push(r)
    }
    Ok(out)
}

fn show(r: List[string]) -> string { "[" + r.join("|") + "]" }

fn same(a: List[string], b: List[string]) -> bool {
    if a.len() != b.len() { return false }
    let i = 0
    while i < a.len() {
        if a.get(i).unwrap_or("") != b.get(i).unwrap_or("") { return false }
        i = i + 1
    }
    true
}

// The single record of a keyed lookup must be exactly `want`.
fn one(facts: Value, label: string, want: List[string]) -> Result[unit, string] {
    let r = rows(facts, label)?
    if r.len() != 1 { return Err(label + ": expected 1 record, got " + str(r.len())) }
    let got = r.get(0).unwrap_or([])
    if !same(got, want) { return Err(label + ": expected " + show(want) + ", got " + show(got)) }
    Ok(())
}

// An enumeration must hold `want` as one of its records.
fn has(facts: Value, label: string, want: List[string]) -> Result[unit, string] {
    let r = rows(facts, label)?
    if !r.any(|x| same(x, want)) { return Err(label + ": no record " + show(want) + " among " + str(r.len())) }
    Ok(())
}

fn gathers(facts: Value) -> Result[bool, string] {
    let alice = ["cwalice", "x", "2101", "2101", "Alice CW,,,", "/home/cwalice", "/bin/bash"]
    let bob = ["cwbob", "x", "2102", "2101", "", "/home/cwbob", "/bin/sh"]
    let empty = ["cwempty", "x", "2103", "2103", "", "", ""]
    let team = ["cwteam", "x", "2201", "cwalice,cwbob"]
    let agroup = ["cwalice", "x", "2101", ""]
    let host1 = ["10.77.0.1", "cw-multi.example", "cw-multi", "cw-alias1"]
    let host2 = ["10.77.0.2", "cw-multi.example", "cw-multi2"]

    one(facts, "pw_name", alice)?
    one(facts, "pw_uid", bob)?
    one(facts, "pw_empty", empty)?
    one(facts, "gr_name", team)?
    one(facts, "gr_gid", agroup)?
    one(facts, "ho_alias", host1)?
    one(facts, "ho_addr", host2)?

    // Two /etc/hosts rows for one name: one record per address.
    let multi = rows(facts, "ho_name")?
    if multi.len() != 2 { return Err("ho_name: expected 2 records, got " + str(multi.len())) }
    for addr in ["10.77.0.1", "10.77.0.2"] {
        if !multi.any(|x| x.get(0).unwrap_or("") == addr && x.get(1).unwrap_or("") == "cw-multi.example") {
            return Err("ho_name: no record for " + addr + " named cw-multi.example")
        }
    }

    for r in [alice, bob, empty, ["root", "x", "0", "0", "root", "/root", "/bin/bash"]] { has(facts, "pw_all", r)? }
    for r in [team, agroup, ["cwempty", "x", "2103", ""], ["root", "x", "0", ""]] { has(facts, "gr_all", r)? }
    has(facts, "ho_all", host1)?
    has(facts, "ho_all", host2)?
    Ok(true)
}

// lookup() with PATH pointing at a fixture directory only.
fn with_path(dir: string, db: string, key: string) -> Result[Value, string] {
    let old = env::get("PATH").unwrap_or("/usr/sbin:/usr/bin:/sbin:/bin")
    env::set("PATH", dir)
    let r = getent_common::lookup(db, key)
    env::set("PATH", old)
    r
}

fn fails(what: string, r: Result[Value, string], needle: string) -> Result[unit, string] {
    if let Err(e) = r {
        if !e.contains(needle) { return Err(what + ": error does not mention '" + needle + "': " + e) }
        return Ok(())
    }
    Err(what + ": expected an error, got a result")
}

fn errors(facts: Value) -> Result[bool, string] {
    for l in ["miss_user", "miss_uid", "miss_group", "miss_host"] {
        let r = rows(facts, l)?
        if !r.is_empty() { return Err(l + ": expected no entries, got " + show(r.get(0).unwrap_or([]))) }
    }

    // Rejected before getent runs. The schema already refuses an
    // undeclared database in a playbook; the script refuses it again.
    fails("database shadow", getent_common::lookup("shadow", ""), "invalid database")?
    fails("database gshadow", getent_common::lookup("gshadow", "root"), "invalid database")?
    fails("key with a newline", getent_common::lookup("passwd", "root\nx"), "line breaks")?
    fails("key with a NUL", getent_common::lookup("passwd", "root\u{0}x"), "NUL")?
    fails("key with a leading -", getent_common::lookup("passwd", "-s"), "must not start with '-'")?

    // PATH fixtures from setup.
    fails("no getent on PATH", with_path("/tmp/cw-getent-none", "passwd", "root"), "cannot run getent")?
    fails("getent exit 1", with_path("/tmp/cw-getent-fail", "passwd", "root"), "exit 1")?
    fails("getent exit 1 stderr", with_path("/tmp/cw-getent-fail", "passwd", "root"), "backend unavailable")?
    fails("enumeration exit 2", with_path("/tmp/cw-getent-exit2", "passwd", ""), "exit 2")?
    fails("enumeration exit 3", with_path("/tmp/cw-getent-exit3", "group", ""), "exit 3")?
    fails("malformed record", with_path("/tmp/cw-getent-bad", "passwd", ""), "malformed passwd record")?
    fails("keyed exit 0 with no output", with_path("/tmp/cw-getent-silent", "passwd", "cwq"), "printed no record")?

    // A keyed exit 2 from the fixture is not found, not an error.
    let nf = with_path("/tmp/cw-getent-exit2", "hosts", "cw-x")?
    if nf.get("found").and_then(|v| v.as_bool()).unwrap_or(true) { return Err("keyed exit 2: found should be false") }

    // Operands reach getent unchanged, after "--".
    let ok = with_path("/tmp/cw-getent-args", "passwd", "a b'c $HOME")?
    if ok.get("count").and_then(|v| v.as_int()).unwrap_or(0) != 1 { return Err("args fixture: expected 1 record") }
    let argv = fs::read("/tmp/cw-getent-args.out")?
    if argv != "--\npasswd\na b'c $HOME\n" { return Err("getent got the wrong operands: " + argv.replace("\n", "|")) }
    Ok(true)
}

fn verify(facts: Value) -> Result[bool, string] {
    if facts.get("pw_name").is_some() { return gathers(facts) }
    if facts.get("miss_user").is_some() { return errors(facts) }
    Err("unknown getent test: no pw_name or miss_user gather")
}
