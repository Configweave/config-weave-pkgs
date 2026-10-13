use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    for inst in ["system", "user"] {
        if !fs::is_file("/var/lib/config-weave/flatpak-updated-" + inst) { return Err("no update stamp for the " + inst + " installation") }
    }
    Ok(true)
}
