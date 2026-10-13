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

// The exact stored value: -z ends it with a NUL rather than a newline, so
// nothing has to be trimmed and edge whitespace is part of the comparison.
fn want_exact(key: string, expected: string) -> Result[bool, string] {
    let got = git("-z --get '" + key + "'")?.stdout
    if got == expected + "\0" { return Ok(true) }
    Err(key + " = '" + got.replace("\0", "") + "', expected exactly '" + expected + "'")
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
        want_all("alias.st", "status -sb")? &&
        want_all("url.git@example.com:.insteadOf", "https://two.invalid/")?

    let raw = want("branch.main.rebase", "true")?

    // Edge whitespace and line breaks survive the round trip.
    let exact = want_exact("alias.padded", "  status  ")? &&
        want_exact("cw.padded", "tail ")? &&
        want_exact("cw.multiline", "first\nsecond")?

    Ok(quoted && removed && multi && raw && exact)
}
