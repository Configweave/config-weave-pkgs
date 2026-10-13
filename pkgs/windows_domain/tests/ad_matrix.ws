// Scenario driver for windows_domain: drives the declared `ad-lab` VMs
// through a full AD topology across real reboots and asserts each stage.
// Run by `config-weave test` via the `testlab` host API. The VMs are
// defined in tests/ad-lab/vmlab.wcl; here we just bring each up by name and
// configure it.
//
//   dc01     forest root for corp.example.com, serves DNS   (domain_controller, :auto creates the forest)
//   member01 joins corp.example.com renamed and into an OU,  (domain_member: new_name, ou_path,
//            has its account moved back and reconciled,       the OU move, ensure = :absent;
//            leaves the domain, then changes workgroup        workgroup_member)
//   dc02     additional DC in site Branch with its own       (domain_controller: site_name, paths,
//            database, log and SYSVOL folders, then demoted   force_removal)
//   dc-alt   a second, independent forest alt.test, then     (domain_controller: forest options,
//            demoted as the last DC of its domain             last_dc_in_domain)
//
// Credentials: the windows-server-2025 template's built-in Administrator is
// `vmlab123!`; after dc01 promotes, that account becomes CORP\Administrator.
//
// Scenario properties reach the engine as quoted strings, which a symbol
// param refuses (and `machine.apply(dir)` cannot run a playbook: it passes
// no play name). So the steps that need a symbol (ensure = :absent,
// mode = :new_forest) are written as a playbook here, copied into the guest
// beside the package, and run with the guest's own config-weave binary.

use testlab
use value
use fs
use path
use json

// Small Value builders so the resource property maps stay readable.
fn s(v: string) -> Value { Value::String(v) }
fn b(v: bool) -> Value { Value::Bool(v) }

// Readers over the windows_domain.membership gatherer's value.
fn gv_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(x) = v.as_string() { return x } }
    ""
}
fn gv_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(x) = v.as_bool() { return x } }
    false
}
fn gv_count(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(l) = v.as_list() { return l.len() } }
    0
}

// The membership facts for a machine, via the package's own gatherer —
// the scenario asserts through the same lens playbooks will use.
fn membership(m: Machine) -> Result[Value, string] {
    m.gather("windows_domain.membership", Value::Null)
}

// ---------------------------------------------------------------- symbols

// Run one step, written as WCL properties (so symbols are allowed), through
// the guest's config-weave in `mode` ("check" or "apply"), and return its
// status and message. `tag` names a fresh guest directory for this call.
fn run_wcl(m: Machine, tag: string, mode: string, resource: string, props: string) -> Result[List[string], string] {
    let dir = fs::temp_dir()?
    let pb = path::join(dir, "playbook.wcl")
    fs::write(pb,
        "playbook \"ad-matrix\" {{\n  description = \"scenario step\"\n  version = \"0.0.0\"\n" +
        "  play \"t\" {{\n    description = \"scenario step\"\n" +
        "    step \"step\" {{\n      description = \"" + tag + "\"\n      resource = \"" + resource + "\"\n" +
        "      properties {{ " + props + " }}\n    }}\n  }}\n}}\n")?
    let guest = "C:/weave/sym/" + tag
    m.copy_in(path::absolutize("pkgs/windows_domain")?, guest + "/pkgs/windows_domain")?
    m.copy_in(pb, guest + "/playbook.wcl")?
    fs::delete_dir(dir)?
    let r = m.exec("C:/weave/config-weave.exe", [mode, guest, "t", "--json", "--continue-on-error"])?
    let report = json::parse(r.stdout.trim())?
    if let Some(steps) = report.get("steps") {
        if let Some(step) = steps.at(0) {
            return Ok([gv_str(step, "status"), gv_str(step, "message")])
        }
    }
    Err(tag + ": no step in the report: " + r.stdout + r.stderr)
}

fn expect_wcl(m: Machine, tag: string, mode: string, resource: string, props: string, want: string) -> Result[string, string] {
    let r = run_wcl(m, tag, mode, resource, props)?
    if r[0] != want { return Err(tag + ": expected " + want + " after " + mode + ", got " + r[0] + " (" + r[1] + ")") }
    Ok(r[1])
}

// The symbol-carrying counterpart of promote() below.
fn promote_wcl(m: Machine, tag: string, resource: string, props: string) -> Result[bool, string] {
    expect_wcl(m, tag + "-apply", "apply", resource, props, "reboot_required")?
    expect_wcl(m, tag + "-pending", "check", resource, props, "reboot_required")?
    m.reboot()?
    expect_wcl(m, tag + "-after", "apply", resource, props, "already_configured")?
    Ok(true)
}

// ---------------------------------------------------------------- helpers

// Apply a reboot-requiring resource, check that it reports the reboot as
// still pending, reboot, and apply again — proving it converges across the
// reboot it asked for.
fn promote(m: Machine, key: string, props: Value) -> Result[bool, string] {
    let r = m.apply_resource(key, props)?
    if r.status != "reboot_required" {
        return Err(key + ": expected reboot_required, got " + r.status + " (" + r.message + ")")
    }
    let p = m.check_resource(key, props)?
    if p.status != "reboot_required" {
        return Err(key + ": before the reboot, check should report reboot_required, got " + p.status + " (" + p.message + ")")
    }
    m.reboot()?
    let r2 = m.apply_resource(key, props)?
    if r2.status != "already_configured" {
        return Err(key + ": did not converge after reboot, got " + r2.status + " (" + r2.message + ")")
    }
    Ok(true)
}

// promote(), allowing one extra reboot for a change finished in two steps.
fn promote_twice(m: Machine, key: string, props: Value) -> Result[bool, string] {
    let r = m.apply_resource(key, props)?
    if r.status != "reboot_required" { return Err(key + ": expected reboot_required, got " + r.status + " (" + r.message + ")") }
    m.reboot()?
    let r2 = m.apply_resource(key, props)?
    if r2.status == "already_configured" { return Ok(true) }
    if r2.status != "reboot_required" { return Err(key + ": after the reboot, got " + r2.status + " (" + r2.message + ")") }
    m.reboot()?
    let r3 = m.apply_resource(key, props)?
    if r3.status != "already_configured" { return Err(key + ": did not converge after a second reboot, got " + r3.status + " (" + r3.message + ")") }
    Ok(true)
}

// Install the AD-DS role and fail loudly if it does not converge.
fn install_role(m: Machine) -> Result[bool, string] {
    let r = m.apply_resource("windows_features.windows_server_feature", Value::Map(#{
        "name": s("AD-Domain-Services"),
        "include_management_tools": b(true)
    }))?
    if !r.ok {
        return Err("AD-DS role install failed: " + r.status + " (" + r.message + ")")
    }
    // The feature can ask for a restart, and promotion refuses to start
    // until it has had one.
    if r.status == "reboot_required" {
        m.reboot()?
        let _ready = settle(m)?
    }
    Ok(true)
}

// Poll an AD query in-guest until `cond` (a PowerShell boolean over $v) holds
// or ~5 minutes elapse, returning the final value. AD Web Services takes a
// while to start after a promotion reboot, so a one-shot Get-ADDomain right
// after `reboot()` races it — this waits it out.
fn ad_wait(m: Machine, value_expr: string, cond: string) -> Result[string, string] {
    let ps = "$ErrorActionPreference='SilentlyContinue'; $v=$null; " +
        "for($i=0; $i -lt 60; $i++){{ try{{ $v=" + value_expr + "; if(" + cond + "){{ break }} }}catch{}; Start-Sleep -Seconds 5 }}; " +
        "\"$v\""
    let r = m.powershell(ps)?
    Ok(r.stdout.trim())
}

fn ps(m: Machine, script: string) -> Result[string, string] {
    let r = m.powershell("$ErrorActionPreference='Stop'; " + script)?
    if r.exit_code != 0 { return Err(m.name() + ": powershell failed: " + r.stderr.trim()) }
    Ok(r.stdout.trim())
}

// Wait until `m` can resolve `name` via its DNS (the DC), so a join/promote
// doesn't race the DC's DNS coming up.
fn wait_resolve(m: Machine, name: string) -> Result[bool, string] {
    let ps = "$ok=$false; for($i=0; $i -lt 60; $i++){{ if(Resolve-DnsName -Name '" + name +
        "' -ErrorAction SilentlyContinue){{ $ok=$true; break }}; Start-Sleep -Seconds 5 }}; " +
        "if($ok){{'ok'}}else{{'no'}}"
    let r = m.powershell(ps)?
    if r.stdout.trim() != "ok" {
        return Err(m.name() + " cannot resolve " + name + " (DC DNS not reachable)")
    }
    Ok(true)
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

fn corp_admin() -> string { "credential_user = \"CORP\\\\Administrator\" credential_password = \"vmlab123!\"" }

fn run(lab: Lab) -> Result[bool, string] {
    // --- dc01: new forest, serving DNS for the corp segment --------------
    // mode defaults to :auto: no credential, no DC answers and the name does
    // not resolve, so the forest is created.
    lab.log("bringing up dc01 (forest root, DNS server)")
    let dc1 = lab.machine("dc01")?
    settle(dc1)?
    install_role(dc1)?
    promote(dc1, "windows_domain.domain_controller",
        Value::Map(#{
            "domain_name": s("corp.example.com"),
            "safe_mode_password": s("P@ssw0rd-DSRM!"),
            "install_dns": b(true)
        }))?
    let d1 = ad_wait(dc1, "(Get-ADDomain).DNSRoot", "$v -eq 'corp.example.com'")?
    if d1 != "corp.example.com" {
        return Err("dc01 is not a DC for corp.example.com: '" + d1 + "'")
    }
    // The forest root holds every FSMO role — assert through the gatherer.
    let m1 = membership(dc1)?
    if !gv_bool(m1, "is_dc") || gv_str(m1, "domain") != "corp.example.com" || gv_str(m1, "netbios_name") != "CORP" {
        return Err("membership gatherer disagrees on dc01: domain '" + gv_str(m1, "domain") + "', netbios '" + gv_str(m1, "netbios_name") + "'")
    }
    let fsmo = gv_count(m1, "fsmo_roles")
    if !gv_bool(m1, "fsmo_known") || fsmo != 5 {
        return Err("dc01 should hold all 5 FSMO roles, gatherer reports {fsmo} (" + gv_str(m1, "fsmo_error") + ")")
    }
    // An OU for member01 and a second site for dc02.
    ps(dc1, "New-ADOrganizationalUnit -Name Servers -Path 'DC=corp,DC=example,DC=com'; New-ADReplicationSite -Name Branch")?
    lab.log("dc01 is up as a DC for corp.example.com (FSMO x5), with OU=Servers and site Branch")

    // --- member01: join renamed, into an OU ------------------------------
    lab.log("bringing up member01 (member server)")
    let mem = lab.machine("member01")?
    settle(mem)?
    wait_resolve(mem, "corp.example.com")?
    let join = Value::Map(#{
        "domain_name": s("corp.example.com"),
        "credential_user": s("CORP\\Administrator"),
        "credential_password": s("vmlab123!"),
        "new_name": s("MEMBER01X"),
        "ou_path": s("OU=Servers,DC=corp,DC=example,DC=com")
    })
    // A rename that could not finish with the join is completed after the
    // first reboot, which asks for one more.
    promote_twice(mem, "windows_domain.domain_member", join)?
    let pm = membership(mem)?
    if !gv_bool(pm, "part_of_domain") || gv_str(pm, "role") != "member_server" || gv_str(pm, "computer_name") != "MEMBER01X" {
        return Err("member01 did not join as MEMBER01X (role '" + gv_str(pm, "role") + "', name '" + gv_str(pm, "computer_name") + "')")
    }
    let where = ad_wait(dc1, "(Get-ADComputer MEMBER01X).DistinguishedName", "$v -like 'CN=MEMBER01X,OU=Servers,*'")?
    if !where.starts_with("CN=MEMBER01X,OU=Servers,") { return Err("MEMBER01X is at '" + where + "', not in OU=Servers") }
    // The NetBIOS name of the domain names the same membership.
    let nb = mem.check_resource("windows_domain.domain_member", Value::Map(#{
        "domain_name": s("CORP"),
        "credential_user": s("CORP\\Administrator"),
        "credential_password": s("vmlab123!")
    }))?
    if nb.status != "already_configured" { return Err("domain_member by NetBIOS name: expected already_configured, got " + nb.status + " (" + nb.message + ")") }
    // The account moved out of its OU is moved back, without a reboot.
    ps(dc1, "Get-ADComputer MEMBER01X | Move-ADObject -TargetPath 'CN=Computers,DC=corp,DC=example,DC=com'")?
    let c = mem.check_resource("windows_domain.domain_member", join)?
    if c.status != "not_configured" { return Err("ou drift: expected not_configured, got " + c.status + " (" + c.message + ")") }
    let a = mem.apply_resource("windows_domain.domain_member", join)?
    if a.status != "configured" { return Err("ou drift: expected configured, got " + a.status + " (" + a.message + ")") }
    let a2 = mem.apply_resource("windows_domain.domain_member", join)?
    if a2.status != "already_configured" { return Err("ou drift: expected already_configured, got " + a2.status + " (" + a2.message + ")") }
    lab.log("member01 joined as MEMBER01X in OU=Servers, and its moved account was put back")

    // A domain that answers is never re-created, even when :new_forest asks.
    let nf = run_wcl(mem, "new-forest", "apply", "windows_domain.domain_controller",
        "domain_name = \"corp.example.com\" mode = :new_forest safe_mode_password = \"P@ssw0rd-DSRM!\"")?
    if nf[0] != "error" || !nf[1].contains("refusing to create a second forest") {
        return Err("mode = :new_forest for an existing domain: expected the refusal, got " + nf[0] + " (" + nf[1] + ")")
    }
    // A credential under :auto means "join", so an unknown domain is an error.
    let ad = mem.apply_resource("windows_domain.domain_controller", Value::Map(#{
        "domain_name": s("nosuch.example.com"),
        "safe_mode_password": s("P@ssw0rd-DSRM!"),
        "credential_user": s("CORP\\Administrator"),
        "credential_password": s("vmlab123!")
    }))?
    if ad.status != "error" || !ad.message.contains("can be found") {
        return Err(":auto with a credential for an unknown domain: expected an error, got " + ad.status + " (" + ad.message + ")")
    }

    // --- dc02: additional DC, in site Branch, with its own folders --------
    lab.log("bringing up dc02 (additional DC)")
    let dc2 = lab.machine("dc02")?
    settle(dc2)?
    wait_resolve(dc2, "corp.example.com")?
    install_role(dc2)?
    promote(dc2, "windows_domain.domain_controller",
        Value::Map(#{
            "domain_name": s("corp.example.com"),
            "safe_mode_password": s("P@ssw0rd-DSRM!"),
            "credential_user": s("CORP\\Administrator"),
            "credential_password": s("vmlab123!"),
            "site_name": s("Branch"),
            "database_path": s("C:\\NTDS2"),
            "log_path": s("C:\\NTDS2LOG"),
            "sysvol_path": s("C:\\SYSVOL2")
        }))?
    let dcs = ad_wait(dc2, "(Get-ADDomainController -Filter *).Count", "$v -ge 2")?
    if dcs == "0" || dcs == "1" {
        return Err("dc02 did not register as a second DC (count='" + dcs + "')")
    }
    let placed = ps(dc2,
        "$n = Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NTDS\\Parameters'; " +
        "[System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name + '|' + (Split-Path $n.'DSA Database file') + '|' + $n.'Database log files path' + '|' + " +
        "(Split-Path (Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Netlogon\\Parameters').SysVol)")?
    if placed.to_upper() != "BRANCH|C:\\NTDS2|C:\\NTDS2LOG|C:\\SYSVOL2" { return Err("dc02 site and folders are '" + placed + "'") }
    // Demoting "a DC of alt.test" must leave this DC of corp alone.
    expect_wcl(dc2, "other-domain", "check", "windows_domain.domain_controller",
        "domain_name = \"alt.test\" ensure = :absent local_admin_password = \"vmlab123!\"", "already_configured")?
    lab.log("dc02 replicated into corp.example.com, in site Branch")

    // --- dc-alt: a second, independent forest with explicit levels ------
    lab.log("bringing up dc-alt (second forest)")
    let alt = lab.machine("dc-alt")?
    settle(alt)?
    install_role(alt)?
    promote(alt, "windows_domain.domain_controller",
        Value::Map(#{
            "domain_name": s("alt.test"),
            "netbios_name": s("ALT"),
            "forest_mode": s("WinThreshold"),
            "domain_mode": s("WinThreshold"),
            "safe_mode_password": s("P@ssw0rd-DSRM!"),
            "install_dns": b(true)
        }))?
    let da = ad_wait(alt, "(Get-ADDomain).DNSRoot", "$v -eq 'alt.test'")?
    if da != "alt.test" {
        return Err("dc-alt is not a DC for alt.test: '" + da + "'")
    }
    lab.log("dc-alt is up as a DC for alt.test")

    // --- dc-alt again: demote the last DC, taking the domain with it ------
    lab.log("demoting dc-alt as the last DC of alt.test")
    promote_wcl(alt, "alt-demote", "windows_domain.domain_controller",
        "domain_name = \"alt.test\" ensure = :absent local_admin_password = \"vmlab123!\" last_dc_in_domain = true")?
    let ma = membership(alt)?
    if gv_bool(ma, "is_dc") || gv_bool(ma, "part_of_domain") {
        return Err("dc-alt is still a DC or domain member after removing the last DC (role '" + gv_str(ma, "role") + "')")
    }
    lab.log("dc-alt demoted (role '" + gv_str(ma, "role") + "')")

    // --- dc02 again: forced demotion -------------------------------------
    lab.log("demoting dc02 with force_removal")
    promote_wcl(dc2, "dc02-demote", "windows_domain.domain_controller",
        "domain_name = \"corp.example.com\" ensure = :absent local_admin_password = \"vmlab123!\" force_removal = true " + corp_admin())?
    let m2 = membership(dc2)?
    if gv_bool(m2, "is_dc") {
        return Err("dc02 is still a DC after demotion (role '" + gv_str(m2, "role") + "')")
    }
    if gv_count(m2, "fsmo_roles") != 0 {
        return Err("demoted dc02 still reports FSMO roles")
    }
    lab.log("dc02 demoted (role '" + gv_str(m2, "role") + "')")

    // --- member01 again: leave the domain, then change workgroup ----------
    lab.log("member01 leaves corp.example.com")
    promote_wcl(mem, "leave", "windows_domain.domain_member",
        "domain_name = \"corp.example.com\" ensure = :absent " + corp_admin())?
    let out = membership(mem)?
    if gv_bool(out, "part_of_domain") || gv_str(out, "workgroup") != "WORKGROUP" {
        return Err("member01 did not land in WORKGROUP (workgroup '" + gv_str(out, "workgroup") + "')")
    }
    lab.log("moving member01 into workgroup TESTWG")
    promote(mem, "windows_domain.workgroup_member", Value::Map(#{ "workgroup_name": s("TESTWG") }))?
    let wg = membership(mem)?
    if gv_bool(wg, "part_of_domain") || gv_str(wg, "workgroup") != "TESTWG" {
        return Err("member01 did not land in TESTWG (workgroup '" + gv_str(wg, "workgroup") + "')")
    }
    lab.log("member01 left the domain and moved into TESTWG")

    Ok(true)
}
