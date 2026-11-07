use value
use shell
use fs

fn listing(py: string) -> Result[List[string], string] {
    let out = shell::bash("PIP_DISABLE_PIP_VERSION_CHECK=1 " + py + " -m pip list --format=freeze", Value::Null)?
    if !out.success { return Err(py + " -m pip list failed: " + out.stderr.trim()) }
    let found = []
    for l in out.stdout.split("\n") {
        if l.trim() != "" { found.push(l.trim().to_lower()) }
    }
    Ok(found)
}

fn named(dists: List[string], name: string) -> bool { dists.any(|l| l.starts_with(name + "==")) }

fn verify(facts: Value) -> Result[bool, string] {
    // PEP 668 was not bypassed: no install, no removal in the system python
    let sys = listing("/usr/local/bin/python3")?
    if named(sys, "cw-sys") { return Err("cw-sys was installed despite the EXTERNALLY-MANAGED marker") }
    if !named(sys, "cw-sys2") { return Err("cw-sys2 was removed despite the EXTERNALLY-MANAGED marker") }
    let inv = listing("/opt/cw/inv/bin/python")?
    let extra = []
    for l in inv { if !l.starts_with("pip==") { extra.push(l) } }
    if !extra.is_empty() { return Err("/opt/cw/inv should hold only pip, it has: " + extra.join(", ")) }
    if fs::lexists("/tmp/cw-pwned") { return Err("shell syntax in a parameter ran") }
    if fs::exists("/opt/cw/no-such-venv") { return Err("a missing virtualenv was created") }
    Ok(true)
}
