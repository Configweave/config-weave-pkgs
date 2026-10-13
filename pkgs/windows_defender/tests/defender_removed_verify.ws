use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$p = Get-MpPreference; $bad = @(); " +
        "if (@($p.ExclusionPath) -contains 'C:\\weave-defender-test') {{ $bad += 'the path exclusion is still there' }}; " +
        "if (@($p.ExclusionProcess) -contains 'weave-test.exe') {{ $bad += 'the process exclusion is still there' }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
