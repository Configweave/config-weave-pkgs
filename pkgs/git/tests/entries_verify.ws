use value
use shell

// The keyed resources and every removal path. Assertions go through git
// rather than string-matching the file: that is the only honest way to
// check a value carrying # and ", which the old hand-rolled INI writer
// silently truncated at the #.
fn git(args: string) -> Result[CmdOutput, string] {
    shell::bash("HOME=/root/entries git config --global " + args, Value::Null)
}

fn want(key: string, expected: string) -> Result[bool, string] {
    let got = git("--get '" + key + "'")?.stdout.trim()
    if got == expected { return Ok(true) }
    Err(key + " = '" + got + "', expected '" + expected + "'")
}

// exit 1 from --get means the key holds no value at all.
fn want_gone(key: string) -> Result[bool, string] {
    if git("--get-all '" + key + "'")?.code == 1 { return Ok(true) }
    let left = git("--get-all '" + key + "'")?.stdout.trim().replace("\n", ", ")
    Err(key + " should be gone, still holds: " + left)
}

fn want_all(key: string, expected: string) -> Result[bool, string] {
    let got = git("--get-all '" + key + "'")?.stdout.trim().replace("\n", ", ")
    if got == expected { return Ok(true) }
    Err(key + " = [" + got + "], expected [" + expected + "]")
}

fn verify(facts: Value) -> Result[bool, string] {
    // The characters the INI writer used to eat.
    let quoted = want("alias.lg", "log --graph --format=\"%h %s\" # pretty")?

    let removed = want_gone("alias.oldco")? &&
        // --unset-all drops every occurrence of a multi-valued key.
        want_gone("http.extraHeader")? &&
        // config_entry is the documented way to unset a section key.
        want_gone("core.editor")?

    // Removing one entry of a multi-valued key must leave its siblings.
    let multi = want_all("safe.directory", "/srv/repo")? &&
        want_all("url.git@example.com:.insteadOf", "https://two.invalid/")?

    let raw = want("branch.main.rebase", "true")?

    Ok(quoted && removed && multi && raw)
}
