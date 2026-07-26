use value
use fs
use shell

// System scope ignores `home` entirely and writes /etc/gitconfig, so this
// reads back through --system rather than --global.
fn want(key: string, expected: string) -> Result[bool, string] {
    let got = shell::bash("git config --system --get '" + key + "'", Value::Null)?.stdout.trim()
    if got == expected { return Ok(true) }
    Err(key + " = '" + got + "', expected '" + expected + "'")
}

fn verify(facts: Value) -> Result[bool, string] {
    let written = want("user.name", "System Wide")? &&
        want("user.email", "sys@example.invalid")? &&
        want("init.defaultBranch", "trunk")?

    // The steps passed no `home`, so nothing may have leaked into a
    // per-user config in root's actual home directory.
    if fs::exists("/root/.gitconfig") {
        return Err("system-scope steps wrote /root/.gitconfig")
    }

    Ok(written)
}
