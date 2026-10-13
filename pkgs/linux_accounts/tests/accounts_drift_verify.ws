use value
use fs

fn passwd(name: string) -> List[string] {
    for line in fs::read("/etc/passwd").unwrap_or("").split("\n") {
        let f = line.split(":")
        if f.get(0).unwrap_or("") == name { return f }
    }
    []
}

fn verify(facts: Value) -> Result[bool, string] {
    let d = passwd("cwdrift")
    if d.len() != 7 { return Err("cwdrift missing") }
    if d.get(2).unwrap_or("") != "3500" { return Err("cwdrift uid not changed: " + d.join(":")) }
    if d.get(3).unwrap_or("") != "2100" { return Err("cwdrift primary gid not changed: " + d.join(":")) }
    if d.get(5).unwrap_or("") != "/srv/cwdrift" || d.get(6).unwrap_or("") != "/bin/bash" { return Err("cwdrift home/shell wrong: " + d.join(":")) }
    if !fs::exists("/srv/cwdrift/keep") || fs::exists("/home/cwdrift") { return Err("cwdrift home not moved") }

    let e = passwd("cwexist")
    if e.get(5).unwrap_or("") != "/srv/cwtaken" { return Err("cwexist home not changed: " + e.join(":")) }
    if !fs::exists("/home/cwexist/keep") || !fs::exists("/srv/cwtaken/theirs") { return Err("existing home directories were disturbed") }

    if !fs::read("/etc/group")?.contains("\ncwgid:x:2201:") { return Err("cwgid gid not changed") }

    let r = passwd("cwreg")
    if r.get(6).unwrap_or("") != "/bin/sh" { return Err("cwreg was modified: " + r.join(":")) }
    if passwd("-ocw").len() > 0 { return Err("option-like user created") }
    Ok(true)
}
