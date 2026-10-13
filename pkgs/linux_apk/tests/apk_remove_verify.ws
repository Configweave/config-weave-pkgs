use value
use fs
use shell

fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("apk info -e " + name + " >/dev/null 2>&1", Value::Null)?.success)
}

fn in_world(spec: string) -> Result[bool, string] {
    for l in fs::read("/etc/apk/world")?.split("\n") { if l.trim() == spec { return Ok(true) } }
    Ok(false)
}

fn verify(facts: Value) -> Result[bool, string] {
    if installed("tree")? { return Err("tree should be removed") }
    if !in_world("libcurl")? { return Err("libcurl should have been added to world") }
    // the guarded removal changed nothing
    if !installed("oniguruma")? || !installed("jq")? { return Err("oniguruma and jq should both still be installed") }
    Ok(true)
}
