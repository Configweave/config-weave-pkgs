use value
use shell

fn run(cmd: string) -> Result[string, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd + " failed: " + out.stderr.trim() + out.stdout.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    // pacman-conf parses pacman.conf the way pacman does.
    let repos = run("pacman-conf --repo-list")?.split("\n")
    if !repos.contains("cw") || !repos.contains("cw-drift") { return Err("cw and cw-drift should be repositories, pacman-conf lists " + repos.join(",")) }
    if repos.contains("cw-old") { return Err("cw-old should be removed") }
    for r in ["cw", "cw-drift"] {
        if run("pacman-conf --repo " + r + " Server")? != "file:///srv/cw-repo" { return Err(r + " has the wrong Server") }
        let sig = run("pacman-conf --repo " + r + " SigLevel")?
        if !sig.contains("Optional") || !sig.contains("TrustAll") { return Err(r + " has SigLevel " + sig) }
    }
    // and pacman can sync and read both
    run("pacman -Sy --noconfirm")?
    run("pacman -Si cw/cw-leaf cw-drift/cw-leaf")?
    Ok(true)
}
