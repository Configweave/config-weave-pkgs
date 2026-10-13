use value
use common

// Every seeded drift is gone, and the bare-name :absent step left
// NT AUTHORITY\NETWORK SERVICE in the group.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps_env("verify",
        common::logon_test_ps() +
        "$u = Get-LocalUser -Name 'weave-drift'; " +
        "$g = Get-LocalGroup -Name 'weave-drift-grp'; " +
        "$flags = [int]([ADSI]'WinNT://./weave-drift,user').UserFlags.Value; " +
        "$sids = @(Get-LocalGroupMember -Group 'weave-drift-grp' | ForEach-Object {{ $_.SID.Value }}); " +
        "$bad = @(); " +
        "if ($u.FullName -ne 'Drift Fixed') {{ $bad += ('full name is ' + $u.FullName) }}; " +
        "if ($u.Description -ne 'fixed') {{ $bad += ('user description is ' + $u.Description) }}; " +
        "if ($u.Enabled) {{ $bad += 'weave-drift is still enabled' }}; " +
        "if (-not ($flags -band 0x10000)) {{ $bad += 'password_never_expires is not set' }}; " +
        // A disabled account still validates its password (error 1331 comes
        // after the password check).
        "if ((Test-CwPassword 'weave-drift' '.' $env:CW_PASSWORD) -ne 'OK') {{ $bad += 'the password was not reset' }}; " +
        "if ($g.Description -ne 'fixed') {{ $bad += ('group description is ' + $g.Description) }}; " +
        "if ($sids -notcontains 'S-1-5-20') {{ $bad += 'NT AUTHORITY\\NETWORK SERVICE was removed from weave-drift-grp' }}; " +
        "$bad -join '; '",
        #{ "CW_PASSWORD": Value::String("Qx7!vTr9pLm2#Zk4") })?
    if out != "" { return Err(out) }
    Ok(true)
}
