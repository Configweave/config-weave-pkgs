use value
use json
use shell

// A mechanical audit of every key the section resources write.
//
// `git help -c` prints git's compiled-in list of every config variable
// (993 on git 2.54); `git config --list --name-only` prints every key
// actually written, lowercased. A key in the second that is missing from
// the first is a typo in some resource's keys() list — the one class of
// bug that otherwise validates, compiles, converges, and then silently
// writes a key git will never read.
//
// This works only because /root/sections is written by the 13 section
// steps alone. git help -c lists templated keys as "alias.*" and
// "branch.<name>.rebase", so the keyed resources would read as typos;
// they are covered by entries_converge against a different home.

// The number of params the 13 section resources declare between them.
// Bump it when params are added: a mismatch means either a param never
// reached git, or the test stopped setting one.
fn expected_key_count() -> int { 141 }

fn num(n: int) -> string { json::to_string(Value::Int(n)) }

fn lines(text: string) -> List[string] {
    let out: List[string] = []
    for l in text.split("\n") {
        if l.trim() != "" { out.push(l.trim().to_lower()) }
    }
    out
}

fn git(args: string) -> Result[CmdOutput, string] {
    shell::bash("HOME=/root/sections git config --global " + args, Value::Null)
}

fn want(key: string, expected: string) -> Result[bool, string] {
    let got = git("--get '" + key + "'")?.stdout.trim()
    if got == expected { return Ok(true) }
    Err(key + " = '" + got + "', expected '" + expected + "'")
}

fn verify(facts: Value) -> Result[bool, string] {
    let known = lines(shell::bash("git help -c", Value::Null)?.stdout)
    // Without this the audit would pass vacuously if git help -c ever
    // went quiet — an empty `known` makes every membership test trivial.
    if known.len() < 500 {
        return Err("git help -c listed only " + num(known.len()) + " variables; the audit would be vacuous")
    }

    let written = lines(git("--list --name-only")?.stdout)
    let unknown: List[string] = []
    for name in written {
        if !known.contains(name) { unknown.push(name) }
    }
    if !unknown.is_empty() {
        return Err("not git config variables (check the keys() list of the resource that writes each): " +
                   unknown.join(", "))
    }
    if written.len() != expected_key_count() {
        return Err("wrote " + num(written.len()) + " keys, expected " + num(expected_key_count()) +
                   " — a parameter either never reached git or is no longer set by the test")
    }

    // One assertion per marshalling path: int, bool, symbol, and a string
    // that git has to quote on the way out.
    let types = want("core.compression", "9")? &&
        want("core.fileMode", "true")? &&
        want("core.autocrlf", "input")? &&
        want("core.commentChar", ";")? &&
        want("core.sshCommand", "ssh -o StrictHostKeyChecking=no")?

    // Every symbol whose git spelling is hyphenated must have survived the
    // underscore translation.
    let hyphenated = want("push.gpgSign", "if-asked")? &&
        want("push.recurseSubmodules", "on-demand")? &&
        want("fetch.recurseSubmodules", "on-demand")? &&
        want("diff.colorMoved", "dimmed-zebra")? &&
        want("rebase.rebaseMerges", "rebase-cousins")? &&
        want("log.diffMerges", "first-parent")?

    Ok(types && hyphenated)
}
