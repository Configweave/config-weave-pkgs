use value
use fs
use hash
use shell

fn verify(facts: Value) -> Result[bool, string] {
    if hash::sha256_file("/srv/dl/payload.txt")? != "d4e4877bac978b7952f0d544fc52ebff5411d351d129f1f056fa43f11da9af2b" {
        return Err("downloaded payload has the wrong digest")
    }
    let out = shell::bash("stat -c '%a' /srv/perm.txt", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "600")
}
