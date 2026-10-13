use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::bash("pacman-conf IgnorePkg", Value::Null)?
    if !out.success { return Err("pacman-conf failed: " + out.stderr.trim()) }
    let held = out.stdout.trim().split("\n")
    if !held.contains("tree") { return Err("tree should be held, IgnorePkg is " + held.join(" ")) }
    if !held.contains("cw-b") { return Err("cw-b should still be held") }
    if held.contains("cw-a") { return Err("cw-a should be released") }
    Ok(true)
}
