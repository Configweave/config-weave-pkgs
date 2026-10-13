use value
use fs
use time

fn verify(facts: Value) -> Result[bool, string] {
    let stamp = "/var/lib/config-weave/pacman-cache-updated"
    if !fs::is_file(stamp) { return Err("cache_updated left no stamp") }
    let m = fs::metadata(stamp)?.get("modified").unwrap_or(Value::Int(0)).as_int().unwrap_or(0)
    if time::now_millis() / 1000 - m > 600 { return Err("the stamp was not rewritten by this run") }
    if !fs::is_file("/var/lib/pacman/sync/core.db") { return Err("pacman -Sy left no core database") }
    Ok(true)
}
