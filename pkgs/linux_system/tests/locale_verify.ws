use value
use fs
use shell

// Whole trimmed lines: "# en_AU.UTF-8 UTF-8" must not count as enabled.
fn has_line(text: string, line: string) -> bool {
    text.split("\n").any(|l| l.trim() == line)
}

fn listed() -> Result[List[string], string] {
    let out = shell::bash("locale -a", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.split("\n").map(|l| l.trim()))
}

fn verify(facts: Value) -> Result[bool, string] {
    let gen = fs::read("/etc/locale.gen")?
    if !has_line(gen, "en_AU.UTF-8 UTF-8") { return Err("en_AU not enabled in /etc/locale.gen") }
    if has_line(gen, "de_DE.UTF-8 UTF-8") { return Err("de_DE still enabled in /etc/locale.gen") }
    if !has_line(gen, "# de_DE.UTF-8 UTF-8") { return Err("de_DE was deleted rather than commented out") }
    let locales = listed()?
    if !locales.contains("en_AU.utf8") { return Err("en_AU.utf8 was not generated") }
    if locales.contains("de_DE.utf8") { return Err("de_DE.utf8 is still generated") }
    Ok(true)
}
