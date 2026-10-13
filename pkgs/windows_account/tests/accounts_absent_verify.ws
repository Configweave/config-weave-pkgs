use value
use common

// The membership, user and group seeded by setup are all gone.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$bad = @(); " +
        "if (Get-LocalUser -Name 'weave-rm' -ErrorAction SilentlyContinue) {{ $bad += 'weave-rm still exists' }}; " +
        "if (Get-LocalGroup -Name 'weave-rm-grp' -ErrorAction SilentlyContinue) {{ $bad += 'weave-rm-grp still exists' }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
