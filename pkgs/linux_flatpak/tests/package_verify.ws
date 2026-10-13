use value
use shell

// application -> origin for the apps of one installation.
fn apps(inst: string) -> Result[Map[string, string], string] {
    let out = shell::bash("flatpak list --" + inst + " --app --columns=application,origin", Value::Null)?
    if !out.success { return Err("flatpak list failed: " + out.stderr.trim()) }
    let m = #{}
    for l in out.stdout.split("\n") {
        let f = l.split("\t")
        if f.len() >= 2 { m.insert(f[0], f[1]) }
    }
    Ok(m)
}

fn verify(facts: Value) -> Result[bool, string] {
    let sys = apps("system")?
    for id in ["org.cw.Other", "org.cw.Hello"] {
        let o = sys.get(id).unwrap_or("not installed")
        if o != "cw" { return Err(id + " should be installed from cw, is " + o) }
    }
    if sys.contains_key("org.cw.Gone") { return Err("org.cw.Gone should be uninstalled") }
    if apps("user")?.get("org.cw.Other").unwrap_or("not installed") != "cw" { return Err("org.cw.Other should be in the user installation") }
    Ok(true)
}
