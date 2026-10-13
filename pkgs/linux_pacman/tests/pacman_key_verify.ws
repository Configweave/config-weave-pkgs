use value
use shell

fn validity(fpr: string) -> Result[string, string] {
    let out = shell::bash("gpg --homedir /etc/pacman.d/gnupg --batch --with-colons --list-keys " + fpr + " 2>/dev/null", Value::Null)?
    if !out.success { return Ok("missing") }
    for l in out.stdout.split("\n") { if l.starts_with("pub:") { return Ok(l.split(":")[1]) } }
    Ok("missing")
}

fn verify(facts: Value) -> Result[bool, string] {
    let v = validity("BF7DF9F280EE40347C9A69FFDC4883058AE970F7")?
    if v != "f" { return Err("the added key should be fully valid (locally signed), gpg says '" + v + "'") }
    if validity("ADE3CC5220B39E775E6C8BBC290DD6D3DF044289")? != "missing" { return Err("the second key should be deleted") }
    Ok(true)
}
