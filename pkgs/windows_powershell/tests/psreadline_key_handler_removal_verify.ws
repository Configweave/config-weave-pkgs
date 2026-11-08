use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let expected = "# before\n$Keep = 'sentinel'\n# BEGIN config-weave: sibling\n$Sibling = 1\n# END config-weave: sibling\n# after\n"
    for name in ["remove", "configured"] {
        if fs::read("/tmp/cfw42-psreadline_key_handler/" + name + ".ps1")? != expected {
            return Err(name + ": unrelated text changed or generated entry survived")
        }
    }
    if fs::exists("/tmp/cfw42-psreadline_key_handler/missing.ps1") { return Err("removal created a missing profile") }
    Ok(true)
}
