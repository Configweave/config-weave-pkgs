use value
use fs

// /etc/zypp/locks holds one blank-line-separated block per lock.
fn verify(facts: Value) -> Result[bool, string] {
    let locks = if fs::is_file("/etc/zypp/locks") { fs::read("/etc/zypp/locks")? } else { "" }
    let names = []
    for l in locks.split("\n") {
        if l.starts_with("solvable_name:") { names.push(l.slice(14, l.len()).trim()) }
    }
    if !names.contains("cw-lock-new") { return Err("cw-lock-new should be locked") }
    if !names.contains("cw-lock-newer") { return Err("cw-lock-newer should still be locked") }
    if names.contains("cw-lock-gone") { return Err("cw-lock-gone should be unlocked") }
    Ok(true)
}
