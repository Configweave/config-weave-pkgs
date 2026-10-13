use value
use fs
use shell

// name:x:uid:gid:gecos:home:shell from the local passwd file
fn passwd(name: string) -> List[string] {
    for line in fs::read("/etc/passwd").unwrap_or("").split("\n") {
        let f = line.split(":")
        if f.get(0).unwrap_or("") == name { return f }
    }
    []
}

fn has_group(name: string) -> bool {
    for line in fs::read("/etc/group").unwrap_or("").split("\n") {
        if line.starts_with(name + ":") { return true }
    }
    false
}

fn verify(facts: Value) -> Result[bool, string] {
    if !fs::read("/etc/group")?.contains("\ncwtest:x:2050:") { return Err("group cwtest missing or gid not 2050") }
    let u = passwd("cwtest")
    if u.len() != 7 { return Err("user cwtest missing") }
    if u.get(2).unwrap_or("") != "3050" || u.get(3).unwrap_or("") != "2050" { return Err("cwtest uid/gid wrong: " + u.join(":")) }
    if u.get(5).unwrap_or("") != "/home/cwtest" || u.get(6).unwrap_or("") != "/bin/sh" { return Err("cwtest home/shell wrong: " + u.join(":")) }
    if !fs::is_dir("/home/cwtest") { return Err("cwtest home not created") }
    let s = passwd("cwsys")
    if s.len() != 7 { return Err("system user cwsys missing") }
    if s.get(2).unwrap_or("").parse_int().unwrap_or(99999) >= 1000 { return Err("cwsys is not a system uid: " + s.join(":")) }

    if fs::read("/etc/sudoers.d/cwtest")? != "cwtest ALL=(ALL:ALL) NOPASSWD: ALL\n" { return Err("cwtest sudoers rule wrong") }
    let mode = shell::bash("stat -c '%a %u %g' /etc/sudoers.d/cwtest", Value::Null)?.stdout.trim()
    if mode != "440 0 0" { return Err("cwtest sudoers drop-in is " + mode) }

    if passwd("cwold").len() > 0 { return Err("cwold not removed") }
    if has_group("cwoldgrp") { return Err("cwoldgrp not removed") }
    if fs::exists("/home/cwold") { return Err("cwold home not removed") }
    if fs::exists("/etc/sudoers.d/cwold") { return Err("cwold sudoers rule not removed") }
    if passwd("cwkeephome").len() > 0 { return Err("cwkeephome not removed") }
    if !fs::is_dir("/home/cwkeephome") { return Err("cwkeephome home removed without remove_home") }
    Ok(true)
}
