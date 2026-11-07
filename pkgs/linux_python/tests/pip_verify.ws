use value
use shell

// "name==version" lines from the environment's own interpreter, read the
// same way the resource reads it: installed metadata, no index.
fn listing(py: string) -> Result[List[string], string] {
    let out = shell::bash("PIP_DISABLE_PIP_VERSION_CHECK=1 " + py + " -m pip list --format=freeze", Value::Null)?
    if !out.success { return Err(py + " -m pip list failed: " + out.stderr.trim()) }
    let found = []
    for l in out.stdout.split("\n") {
        if l.trim() != "" { found.push(l.trim().to_lower()) }
    }
    Ok(found)
}

fn has(dists: List[string], want: string) -> bool { dists.any(|l| l == want) }

fn named(dists: List[string], name: string) -> bool { dists.any(|l| l.starts_with(name + "==")) }

fn verify(facts: Value) -> Result[bool, string] {
    let main = listing("/opt/cw/main/bin/python")?
    for want in ["cw-fresh==2.0", "cw-latest==2.0", "cw-drift==2.0", "cw-down==1.0", "cw-same==2.0", "cw-zeros==2.0", "cw-any==1.0"] {
        if !has(main, want) { return Err("/opt/cw/main should hold " + want + ", it has:\n" + main.join("\n")) }
    }
    for gone in ["cw-gone", "cw-app", "cw-never", "cw-exe"] {
        if named(main, gone) { return Err(gone + " should not be installed in /opt/cw/main:\n" + main.join("\n")) }
    }
    // removing cw-app leaves the dependency it pulled in
    if !named(main, "cw-lib") { return Err("cw-lib, a dependency of the removed cw-app, was removed too") }

    let exe = listing("/opt/cw/exe/bin/python")?
    if !has(exe, "cw-exe==1.0") { return Err("/opt/cw/exe should hold cw-exe==1.0, it has:\n" + exe.join("\n")) }
    let sys = listing("/usr/local/bin/python3")?
    for n in ["cw-exe", "cw-fresh", "cw-latest"] {
        if named(sys, n) { return Err(n + " was installed into the system python") }
    }
    Ok(true)
}
