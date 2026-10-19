use value
use fs
use hash
use shell

fn mode(p: string) -> Result[string, string] {
    let out = shell::bash("stat -c '%a' -- '" + p + "'", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    if hash::sha256_file("/srv/dl/payload.txt")? != "d4e4877bac978b7952f0d544fc52ebff5411d351d129f1f056fa43f11da9af2b" {
        return Err("downloaded payload has the wrong digest")
    }
    if mode("/srv/dl/payload.txt")? != "644" { return Err("payload.txt mode not 644") }
    // the failed download must not have replaced the file or left its temp
    if fs::read("/srv/dl/keep.txt")? != "old\n" { return Err("a download with a bad digest replaced keep.txt") }
    if !fs::glob("/srv/dl/.*.cw-tmp")?.is_empty() { return Err("a failed download left its temp file") }
    for f in ["/srv/dl/truncated.txt", "/srv/dl/fresh.txt"] {
        if fs::read(f)? != "payload\n" { return Err(f + " does not hold the download") }
    }
    for f in ["/srv/dl/wrong-size.txt", "/srv/dl/content.txt"] {
        if fs::lexists(f) { return Err(f + " should not exist") }
    }
    if mode("/srv/perm.txt")? != "600" { return Err("perm.txt mode not 600") }
    Ok(true)
}
