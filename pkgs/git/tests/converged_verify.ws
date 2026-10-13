use value
use shell

// The two drift steps rewrote their keys to the exact desired text, and
// the folded steps left the seeded spellings alone.
fn git(args: string) -> Result[CmdOutput, string] {
    shell::bash("HOME=/root/converged git config --global " + args, Value::Null)
}

fn want(key: string, expected: string) -> Result[bool, string] {
    let got = git("-z --get-all '" + key + "'")?.stdout
    if got == expected + "\0" { return Ok(true) }
    Err(key + " = '" + got.replace("\0", "|") + "', expected exactly '" + expected + "'")
}

fn verify(facts: Value) -> Result[bool, string] {
    let rewritten = want("merge.log", "1")? && want("fetch.parallel", "1")? && want("cw.count", "1")?
    let untouched = want("core.fileMode", "yes")? &&
        want("pull.autoStash", "on")? &&
        want("fetch.prune", "1")? &&
        want("status.short", "")? &&
        want("cw.flag", "yes")?
    Ok(rewritten && untouched)
}
