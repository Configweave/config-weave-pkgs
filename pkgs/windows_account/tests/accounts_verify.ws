use value
use common

// weave-svc exists, is enabled, never-expires is set, its password validates,
// and it is in weave-ops (by SID).
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps_env("verify",
        common::logon_test_ps() +
        "$u = Get-LocalUser -Name 'weave-svc'; " +
        "$flags = [int]([ADSI]'WinNT://./weave-svc,user').UserFlags.Value; " +
        "$sids = @(Get-LocalGroupMember -Group 'weave-ops' | ForEach-Object {{ $_.SID.Value }}); " +
        "$bad = @(); " +
        "if (-not $u.Enabled) {{ $bad += 'weave-svc is disabled' }}; " +
        "if ($u.FullName -ne 'Weave Service') {{ $bad += ('full name is ' + $u.FullName) }}; " +
        "if (-not ($flags -band 0x10000)) {{ $bad += 'password_never_expires is not set' }}; " +
        "if ((Test-CwPassword 'weave-svc' '.' $env:CW_PASSWORD) -ne 'OK') {{ $bad += 'the password does not validate' }}; " +
        "if ($sids -notcontains $u.SID.Value) {{ $bad += 'weave-svc is not in weave-ops' }}; " +
        "$bad -join '; '",
        #{ "CW_PASSWORD": Value::String("Qx7!vTr9pLm2#Zk4") })?
    if out != "" { return Err(out) }
    Ok(true)
}
