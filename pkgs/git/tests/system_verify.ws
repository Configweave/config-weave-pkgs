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

    // Add one entry, remove the seeded one.
    let safe = shell::bash("git config --system --get-all safe.directory", Value::Null)?.stdout.trim()
    if safe != "/srv/sys-repo" {
        return Err("safe.directory = [" + safe.replace("\n", ", ") + "], expected [/srv/sys-repo]")
    }

    // Nothing may have leaked into a per-user config: not root's actual
    // home, and not the `home` one system-scope step passed.
    if fs::exists("/root/.gitconfig") {
        return Err("system-scope steps wrote /root/.gitconfig")
    }
    if fs::exists("/root/not-a-home") {
        return Err("a system-scope step created its ignored home, /root/not-a-home")
    }

    Ok(written)
}
