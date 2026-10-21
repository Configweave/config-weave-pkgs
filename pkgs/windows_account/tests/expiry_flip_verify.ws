use value
use common

// weave-exp's password expires again (a date comes back) while its account,
// unmanaged in this test, still never expires.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$e = Get-LocalUser -Name 'weave-exp'; " +
        "$bad = @(); " +
        "if ($null -eq $e.PasswordExpires) {{ $bad += 'weave-exp password still never expires' }}; " +
        "if ($null -ne $e.AccountExpires) {{ $bad += ('weave-exp AccountExpires is ' + $e.AccountExpires) }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
