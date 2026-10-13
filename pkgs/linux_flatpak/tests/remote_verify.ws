use value
use shell

// name -> "url options" for one installation, as flatpak lists them.
fn remotes(inst: string) -> Result[Map[string, string], string] {
    let out = shell::bash("flatpak remotes --" + inst + " --show-disabled --columns=name,url,options", Value::Null)?
    if !out.success { return Err("flatpak remotes failed: " + out.stderr.trim()) }
    let m = #{}
    for l in out.stdout.split("\n") {
        let f = l.split("\t")
        if f.len() >= 2 { m.insert(f[0], f[1] + " " + if f.len() >= 3 { f[2] } else { "" }) }
    }
    Ok(m)
}

fn verify(facts: Value) -> Result[bool, string] {
    let sys = remotes("system")?
    let want = "file:///srv/cw-flatpak no-gpg-verify"
    for n in ["cw", "cw-disabled"] {
        let got = sys.get(n).unwrap_or("missing")
        if got != want { return Err(n + " should be '" + want + "', is '" + got + "'") }
    }
    let url = sys.get("cw-url").unwrap_or("missing")
    if !url.starts_with("file:///srv/cw-flatpak") || url.contains("cw-old") { return Err("cw-url should point at the repository, is '" + url + "'") }
    if sys.contains_key("cw-gone") { return Err("cw-gone should be deleted") }
    if remotes("user")?.get("cw-user").unwrap_or("missing") != want { return Err("cw-user should be in the user installation") }
    Ok(true)
}
