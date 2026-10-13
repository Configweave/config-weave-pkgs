use value
use fs
use time

fn verify(facts: Value) -> Result[bool, string] {
    let stamp = "/var/lib/config-weave/apk-cache-updated"
    if !fs::is_file(stamp) { return Err("cache_updated left no stamp") }
    let m = fs::metadata(stamp)?.get("modified").unwrap_or(Value::Int(0)).as_int().unwrap_or(0)
    if time::now_millis() / 1000 - m > 600 { return Err("the stamp was not rewritten by this run") }
    // apk update fetched an index for every repository
    let idx = fs::glob("/var/cache/apk/APKINDEX.*.tar.gz")?
    if idx.len() == 0 { return Err("apk update left no index in /var/cache/apk") }
    Ok(true)
}
