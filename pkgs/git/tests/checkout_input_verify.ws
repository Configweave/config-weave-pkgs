use value
use fs

// checkout_invalid_input: no injection attempt ran, and no rejected step
// created anything.
fn verify(facts: Value) -> Result[bool, string] {
    if fs::lexists("/tmp/cw-injected") { return Err("/tmp/cw-injected exists: an input reached a shell or git as an option") }
    let left = fs::list_dir("/srv/cw-co/input")?
    if !left.is_empty() { return Err("rejected steps created: " + left.join(", ")) }
    if fs::lexists("/srv/cw-co/escape") { return Err("/srv/cw-co/escape was created") }
    Ok(true)
}
