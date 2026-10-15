// Scenario driver for windows_account's AD resources: one server is promoted
// to the first DC of acct.test (with plain PowerShell, so this package needs
// no other), then ad_user, ad_group and ad_group_member converge against it,
// have drift seeded behind their backs, and converge again.
//
// Symbol params (ensure = :absent, scope = :domainlocal) are passed as plain
// strings: testlab renders a top-level string as a symbol when the param is
// declared `type = "symbol"`.

use testlab
use value

fn s(v: string) -> Value { Value::String(v) }

fn ps(m: Machine, script: string) -> Result[string, string] {
    let r = m.powershell("$ErrorActionPreference='Stop'; " + script)?
    if r.exit_code != 0 { return Err("powershell failed: " + r.stderr.trim() + r.stdout.trim()) }
    Ok(r.stdout.trim())
}

// check, apply, apply: the three-run protocol a `test` step gets.
fn converge(m: Machine, key: string, props: Value) -> Result[bool, string] {
    let c = m.check_resource(key, props)?
    if c.status != "not_configured" { return Err(key + ": expected not_configured on check, got " + c.status + " (" + c.message + ")") }
    let a = m.apply_resource(key, props)?
    if a.status != "configured" { return Err(key + ": expected configured on first apply, got " + a.status + " (" + a.message + ")" + diagnose(m)) }
    let b = m.apply_resource(key, props)?
    if b.status != "already_configured" { return Err(key + ": expected already_configured on second apply, got " + b.status + " (" + b.message + ")") }
    Ok(true)
}

// What the directory holds for the test users, to explain a failed step.
fn diagnose(m: Machine) -> string {
    if let Ok(r) = m.powershell("Get-ADUser -Filter \"Name -like 'weave-*'\" -Properties DisplayName,UserPrincipalName,Enabled,PasswordLastSet | " +
        "ForEach-Object {{ $_.DistinguishedName + ' | ' + $_.UserPrincipalName + ' | ' + $_.DisplayName + ' | enabled=' + $_.Enabled + ' | pwdLastSet=' + $_.PasswordLastSet }}") {
        return "\n" + r.stdout.trim() + r.stderr.trim()
    }
    ""
}

fn expect(m: Machine, key: string, props: Value, want: string) -> Result[bool, string] {
    let c = m.check_resource(key, props)?
    if c.status != want { return Err(key + ": expected " + want + " on check, got " + c.status + " (" + c.message + ")") }
    Ok(true)
}

// Whether `pw` is the password of ACCT\<user>, by binding to the directory
// as that user.
fn password_ok(m: Machine, user: string, pw: string) -> Result[bool, string] {
    let out = ps(m, "try {{ $e = New-Object System.DirectoryServices.DirectoryEntry('LDAP://acct.test', 'ACCT\\" + user + "', '" + pw + "'); [void]$e.NativeObject; 'OK' }} catch {{ 'BAD' }}")?
    Ok(out == "OK")
}

// A freshly booted guest's vmlab agent can drop the channel on its first
// execs while it settles (vmlab updates and restarts it), so the first
// contact is retried until a trivial command answers.
fn settle(m: Machine) -> Result[bool, string] {
    for i in 0..30 {
        if let Ok(r) = m.powershell("'ok'") {
            if r.stdout.trim() == "ok" { return Ok(true) }
        }
        if let Err(_) = m.wait_ready(60) { }
    }
    Err(m.name() + ": the guest agent never answered a command")
}

fn run(lab: Lab) -> Result[bool, string] {
    let dc = lab.machine("dc")?
    settle(dc)?
    // ad_user guards on the missing ActiveDirectory module before promotion.
    let pre = dc.check_resource("windows_account.ad_user", Value::Map(#{ "name": s("weave-ad1") }))?
    if pre.status != "error" { return Err("ad_user before promotion: expected the module guard error, got " + pre.status) }

    lab.log("promoting dc to the first DC of acct.test")
    ps(dc, "Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null; " +
        "Install-ADDSForest -DomainName acct.test -DomainNetbiosName ACCT -InstallDns " +
        "-SafeModeAdministratorPassword (ConvertTo-SecureString 'P@ssw0rd-DSRM!' -AsPlainText -Force) " +
        "-Force -NoRebootOnCompletion -WarningAction SilentlyContinue | Out-Null")?
    dc.reboot()?
    // AD Web Services, and the DC locator the password check's logon goes
    // through, both come up a while after the promotion reboot.
    ps(dc, "$ErrorActionPreference='SilentlyContinue'; for ($i = 0; $i -lt 90; $i++) {{ if ((Get-ADDomain).DNSRoot -eq 'acct.test') {{ break }}; Start-Sleep 5 }}; " +
        "for ($i = 0; $i -lt 60; $i++) {{ & cmd.exe /c 'nltest /dsgetdc:acct.test >nul 2>&1'; if ($LASTEXITCODE -eq 0) {{ break }}; Start-Sleep 5 }}; " +
        "$ErrorActionPreference='Stop'; New-ADOrganizationalUnit -Name Staff -Path 'DC=acct,DC=test'")?
    let staff = "OU=Staff,DC=acct,DC=test"

    // --- ad_user ---------------------------------------------------------
    let user = Value::Map(#{
        "name": s("weave-ad1"),
        "password": s("Qx7!vTr9pLm2#Zk4"),
        "upn": s("weave-ad1@acct.test"),
        "display_name": s("Weave One"),
        "ou_path": s(staff)
    })
    converge(dc, "windows_account.ad_user", user)?
    if !password_ok(dc, "weave-ad1", "Qx7!vTr9pLm2#Zk4")? { return Err("weave-ad1 does not accept its password") }
    lab.log("drifting weave-ad1: password, display name, enabled, OU")
    ps(dc, "Set-ADAccountPassword -Identity weave-ad1 -Reset -NewPassword (ConvertTo-SecureString 'Other-Pw-9911!' -AsPlainText -Force); " +
        "Set-ADUser -Identity weave-ad1 -DisplayName Wrong -Enabled $false; " +
        "Get-ADUser weave-ad1 | Move-ADObject -TargetPath 'CN=Users,DC=acct,DC=test'")?
    converge(dc, "windows_account.ad_user", user)?
    let u = ps(dc, "$u = Get-ADUser weave-ad1 -Properties DisplayName; $u.DistinguishedName + '|' + $u.DisplayName + '|' + $u.Enabled")?
    if u != "CN=weave-ad1," + staff + "|Weave One|True" { return Err("weave-ad1 after reconcile: " + u) }
    if !password_ok(dc, "weave-ad1", "Qx7!vTr9pLm2#Zk4")? { return Err("weave-ad1's password was not reset") }
    // A second user, to be a member by DN.
    converge(dc, "windows_account.ad_user", Value::Map(#{ "name": s("weave-ad2"), "password": s("Qx7!vTr9pLm2#Zk4"), "ou_path": s(staff) }))?

    // --- ad_group --------------------------------------------------------
    let grp = Value::Map(#{ "name": s("weave-grp"), "ou_path": s(staff), "server": s("acct.test") })
    converge(dc, "windows_account.ad_group", grp)?
    // Global -> DomainLocal has no direct conversion; it steps via Universal.
    converge(dc, "windows_account.ad_group", Value::Map(#{ "name": s("weave-grp"), "scope": s("domainlocal"), "ou_path": s(staff) }))?
    let scope = ps(dc, "[string](Get-ADGroup weave-grp).GroupScope")?
    if scope != "DomainLocal" { return Err("weave-grp scope is " + scope) }
    lab.log("weave-grp moved from Global to DomainLocal")

    // --- ad_group_member -------------------------------------------------
    converge(dc, "windows_account.ad_group_member", Value::Map(#{ "group": s("weave-grp"), "member": s("weave-ad1") }))?
    converge(dc, "windows_account.ad_group_member", Value::Map(#{ "group": s("weave-grp"), "member": s("CN=weave-ad2," + staff) }))?
    // Domain Users is every user's primary group: a member, though not in
    // the group's 'member' attribute.
    expect(dc, "windows_account.ad_group_member", Value::Map(#{ "group": s("Domain Users"), "member": s("weave-ad1") }), "already_configured")?
    expect(dc, "windows_account.ad_group_member", Value::Map(#{ "group": s("Domain Users"), "member": s("weave-ad1"), "ensure": s("absent") }), "error")?
    converge(dc, "windows_account.ad_group_member", Value::Map(#{ "group": s("weave-grp"), "member": s("weave-ad1"), "ensure": s("absent") }))?
    let members = ps(dc, "(@(Get-ADGroupMember weave-grp | ForEach-Object {{ $_.SamAccountName }}) | Sort-Object) -join ','")?
    if members != "weave-ad2" { return Err("weave-grp members: " + members) }

    // --- removal ---------------------------------------------------------
    converge(dc, "windows_account.ad_group", Value::Map(#{ "name": s("weave-grp"), "ensure": s("absent") }))?
    converge(dc, "windows_account.ad_user", Value::Map(#{ "name": s("weave-ad2"), "ensure": s("absent") }))?
    let gone = ps(dc, "$g = Get-ADGroup -Filter \"Name -eq 'weave-grp'\"; $u = Get-ADUser -Filter \"Name -eq 'weave-ad2'\"; [string]([bool]$g) + [string]([bool]$u)")?
    if gone != "FalseFalse" { return Err("weave-grp or weave-ad2 survived removal: " + gone) }
    lab.log("ad_user, ad_group and ad_group_member converged, reconciled and removed")
    Ok(true)
}
