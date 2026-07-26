use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // runit itself must report cw-stop down, and cw-enable must be linked
    // into the active service directory.
    let status = shell::bash("sv status /var/service/cw-stop", Value::Null)?
    if !status.success { return Err("sv status failed: " + status.stderr.trim()) }
    let stopped = status.stdout.trim().starts_with("down:")
    Ok(stopped && fs::read_link("/var/service/cw-enable").is_ok())
}
