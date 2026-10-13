use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::bash("locale -a", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let locales = out.stdout.split("\n").map(|l| l.trim())
    if !locales.contains("en_AU.utf8") { return Err("en_AU.utf8 was not built") }
    if locales.contains("de_DE.utf8") { return Err("de_DE.utf8 is still installed") }
    Ok(true)
}
