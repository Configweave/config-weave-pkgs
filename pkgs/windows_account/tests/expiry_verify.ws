use value
use common

// weave-exp's password and account no longer expire; weave-plain, which
// named neither param, still has the expiring password setup gave it.
// weave-nopw has no password and DONT_EXPIRE_PASSWD clear. Windows still
// shows it no PasswordExpires date, because a password that was never set
// has no PasswordLastSet to count from, so the flag is what is checked.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$e = Get-LocalUser -Name 'weave-exp'; " +
        "$p = Get-LocalUser -Name 'weave-plain'; " +
        "$n = Get-LocalUser -Name 'weave-nopw'; " +
        "$nflags = [int]([ADSI]'WinNT://./weave-nopw,user').UserFlags.Value; " +
        "$bad = @(); " +
        "if ($null -ne $e.PasswordExpires) {{ $bad += ('weave-exp PasswordExpires is ' + $e.PasswordExpires) }}; " +
        "if ($null -ne $e.AccountExpires) {{ $bad += ('weave-exp AccountExpires is ' + $e.AccountExpires) }}; " +
        "if ($null -eq $p.PasswordExpires) {{ $bad += 'weave-plain password no longer expires' }}; " +
        "if ($nflags -band 0x10000) {{ $bad += 'weave-nopw has DONT_EXPIRE_PASSWD set' }}; " +
        "if ($null -ne $n.AccountExpires) {{ $bad += ('weave-nopw AccountExpires is ' + $n.AccountExpires) }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
