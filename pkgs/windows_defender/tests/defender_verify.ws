use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "if (@((Get-MpPreference).ExclusionPath) -contains 'C:\\weave-defender-test') {{ '' }} else {{ 'the path exclusion is missing' }}")?
    if out != "" { return Err(out) }
    Ok(true)
}
