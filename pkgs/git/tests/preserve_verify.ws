use value
use json
use shell

// The step set core.editor and nothing else, so every other seeded key —
// including two more in the same [core] section — must be untouched. This
// is the contract that justifies section params carrying no default: an
// omitted param is absent from the params map, and absence means "leave
// this setting alone".
fn git(args: string) -> Result[CmdOutput, string] {
    shell::bash("HOME=/root/preserve git config --global " + args, Value::Null)
}

fn want(key: string, expected: string) -> Result[bool, string] {
    let got = git("--get '" + key + "'")?.stdout.trim()
    if got == expected { return Ok(true) }
    Err(key + " = '" + got + "', expected '" + expected + "'")
}

fn verify(facts: Value) -> Result[bool, string] {
    let applied = want("core.editor", "nano")?

    let untouched = want("core.pager", "less")? &&
        want("core.autocrlf", "true")? &&
        want("user.email", "seed@example.invalid")? &&
        want("alias.co", "checkout")?

    // Nothing else may have appeared either: the seeded four plus editor.
    let count = git("--list --name-only")?.stdout.trim().split("\n").len()
    if count != 5 {
        return Err("config holds " + json::to_string(Value::Int(count)) + " keys, expected 5")
    }

    Ok(applied && untouched)
}
