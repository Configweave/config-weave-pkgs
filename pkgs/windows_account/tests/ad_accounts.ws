// Scenario driver for windows_account's AD resources: one server is promoted
// to the first DC of acct.test (with plain PowerShell, so this package needs
// no other), then ad_user, ad_group and ad_group_member converge against it,
// have drift seeded behind their backs, and converge again.
//
// Scenario properties reach the engine as quoted strings, which a symbol
// param refuses (and `machine.apply(dir)` cannot run a playbook: it passes
// no play name). So the steps that need a symbol (ensure = :absent,
// scope = :domainlocal) are written as a playbook here, copied into the
// guest beside the package, and run with the guest's own config-weave.

use testlab
use value
use fs
use path
use json

fn s(v: string) -> Value { Value::String(v) }

fn str_of(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(x) = v.as_string() { return x } }
    ""
}

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
    if a.status != "configured" { return Err(key + ": expected configured on first apply, got " + a.status + " (" + a.message + ")") }
    let b = m.apply_resource(key, props)?
    if b.status != "already_configured" { return Err(key + ": expected already_configured on second apply, got " + b.status + " (" + b.message + ")") }
    Ok(true)
}

fn expect(m: Machine, key: string, props: Value, want: string) -> Result[bool, string] {
    let c = m.check_resource(key, props)?
    if c.status != want { return Err(key + ": expected " + want + " on check, got " + c.status + " (" + c.message + ")") }
    Ok(true)
}

// One step written as WCL properties, run through the guest's config-weave.
fn run_wcl(m: Machine, tag: string, mode: string, resource: string, props: string) -> Result[List[string], string] {
    let dir = fs::temp_dir()?
    let pb = path::join(dir, "playbook.wcl")
    fs::write(pb,
        "playbook \"ad-accounts\" {{\n  description = \"scenario step\"\n  version = \"0.0.0\"\n" +
        "  play \"t\" {{\n    description = \"scenario step\"\n" +
        "    step \"step\" {{\n      description = \"" + tag + "\"\n      resource = \"" + resource + "\"\n" +
        "      properties {{ " + props + " }}\n    }}\n  }}\n}}\n")?
    let guest = "C:/weave/sym/" + tag
    m.copy_in(path::absolutize("pkgs/windows_account")?, guest + "/pkgs/windows_account")?
    m.copy_in(pb, guest + "/playbook.wcl")?
    fs::delete_dir(dir)?
    let r = m.exec("C:/weave/config-weave.exe", [mode, guest, "t", "--json", "--continue-on-error"])?
    let report = json::parse(r.stdout.trim())?
    if let Some(steps) = report.get("steps") {
        if let Some(step) = steps.at(0) {
            return Ok([str_of(step, "status"), str_of(step, "message")])
        }
    }
    Err(tag + ": no step in the report: " + r.stdout + r.stderr)
}

fn converge_wcl(m: Machine, tag: string, resource: string, props: string) -> Result[bool, string] {
    let want = ["not_configured", "configured", "already_configured"]
    let modes = ["check", "apply", "apply"]
    for i in 0..3 {
        let r = run_wcl(m, tag + "-{i}", modes[i], resource, props)?
        if r[0] != want[i] { return Err(tag + ": expected " + want[i] + " on run {i}, got " + r[0] + " (" + r[1] + ")") }
    }
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
        m.wait_ready(60)?
    }
    Err(m.name() + ": the guest agent never answered a command")
}

fn run(lab: Lab) -> Result[bool, string] {
    let dc = lab.machine("dc")?
    settle(dc)?
    // The first resource call stages config-weave in the guest, which
    // run_wcl relies on; ad_user guarding on the missing module is that call.
    let pre = dc.check_resource("windows_account.ad_user", Value::Map(#{ "name": s("weave-ad1") }))?
    if pre.status != "error" { return Err("ad_user before promotion: expected the module guard error, got " + pre.status) }

    lab.log("promoting dc to the first DC of acct.test")
    ps(dc, "Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null; " +
        "Install-ADDSForest -DomainName acct.test -DomainNetbiosName ACCT -InstallDns " +
        "-SafeModeAdministratorPassword (ConvertTo-SecureString 'P@ssw0rd-DSRM!' -AsPlainText -Force) " +
        "-Force -NoRebootOnCompletion -WarningAction SilentlyContinue | Out-Null")?
    dc.reboot()?
    ps(dc, "$ErrorActionPreference='SilentlyContinue'; for ($i = 0; $i -lt 90; $i++) {{ if ((Get-ADDomain).DNSRoot -eq 'acct.test') {{ break }}; Start-Sleep 5 }}; " +
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
    converge_wcl(dc, "grp-domainlocal", "windows_account.ad_group",
        "name = \"weave-grp\" scope = :domainlocal ou_path = \"" + staff + "\"")?
    let scope = ps(dc, "[string](Get-ADGroup weave-grp).GroupScope")?
    if scope != "DomainLocal" { return Err("weave-grp scope is " + scope) }
    lab.log("weave-grp moved from Global to DomainLocal")

    // --- ad_group_member -------------------------------------------------
    converge(dc, "windows_account.ad_group_member", Value::Map(#{ "group": s("weave-grp"), "member": s("weave-ad1") }))?
    converge(dc, "windows_account.ad_group_member", Value::Map(#{ "group": s("weave-grp"), "member": s("CN=weave-ad2," + staff) }))?
    // Domain Users is every user's primary group: a member, though not in
    // the group's 'member' attribute.
    expect(dc, "windows_account.ad_group_member", Value::Map(#{ "group": s("Domain Users"), "member": s("weave-ad1") }), "already_configured")?
    let prim = run_wcl(dc, "primary-absent", "check", "windows_account.ad_group_member",
        "group = \"Domain Users\" member = \"weave-ad1\" ensure = :absent")?
    if prim[0] != "error" { return Err("removing a primary-group membership: expected an error, got " + prim[0]) }
    converge_wcl(dc, "member-absent", "windows_account.ad_group_member",
        "group = \"weave-grp\" member = \"weave-ad1\" ensure = :absent")?
    let members = ps(dc, "(@(Get-ADGroupMember weave-grp | ForEach-Object {{ $_.SamAccountName }}) | Sort-Object) -join ','")?
    if members != "weave-ad2" { return Err("weave-grp members: " + members) }

    // --- removal ---------------------------------------------------------
    converge_wcl(dc, "group-absent", "windows_account.ad_group", "name = \"weave-grp\" ensure = :absent")?
    converge_wcl(dc, "user-absent", "windows_account.ad_user", "name = \"weave-ad2\" ensure = :absent")?
    let gone = ps(dc, "$g = Get-ADGroup -Filter \"Name -eq 'weave-grp'\"; $u = Get-ADUser -Filter \"Name -eq 'weave-ad2'\"; [string]([bool]$g) + [string]([bool]$u)")?
    if gone != "FalseFalse" { return Err("weave-grp or weave-ad2 survived removal: " + gone) }
    lab.log("ad_user, ad_group and ad_group_member converged, reconciled and removed")
    Ok(true)
}
