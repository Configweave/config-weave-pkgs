use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // flatpak itself must list the remote, enabled, at the URL the
    // descriptor names.
    let out = shell::bash("flatpak remotes --system --show-disabled --columns=name,url,options", Value::Null)?
    for l in out.stdout.split("\n") {
        let f = l.split("\t")
        if f.len() >= 2 && f[0] == "flathub" {
            if f.len() >= 3 && f[2].contains("disabled") { return Err("flathub is disabled") }
            if !f[1].starts_with("https://dl.flathub.org/repo") { return Err("flathub points at " + f[1]) }
            return Ok(true)
        }
    }
    Err("flathub is not a system remote")
}
