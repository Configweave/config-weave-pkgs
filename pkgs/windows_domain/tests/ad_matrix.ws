// Scenario driver for windows_domain: drives the declared `ad-lab` VMs
// through a full AD topology across real reboots and asserts each stage.
// Run by `config-weave test` via the `testlab` host API. The VMs are
// defined in tests/ad-lab/vmlab.wcl; here we just bring each up by name and
// configure it.
//
//   dc01     forest root for corp.example.com, serves DNS   (domain_controller, first DC)
//   member01 member server joining corp.example.com, then    (domain_member,
//            leaving it for a workgroup                       workgroup_member)
//   dc02     additional DC replicated into corp.example.com, (domain_controller,
//            then demoted again                               ensure = :absent)
//   dc-alt   a second, independent forest alt.test           (domain_controller, first DC)
//
// The same domain_controller resource serves every DC stage: promotion
// discovers whether the domain answers (first DC vs additional DC) and
// ensure = :absent demotes.
//
// Credentials: the windows-server-2025 template's built-in Administrator is
// `vmlab123!`; after dc01 promotes, that account becomes CORP\Administrator.

use testlab
use value

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

// The AD-DS role install, applied before any promotion (the promotion
// cmdlets ship with this role).
fn role() -> Value {
    Value::Map(#{
        "name": Value::String("AD-Domain-Services"),
        "include_management_tools": Value::Bool(true)
    })
}

// Apply a reboot-requiring resource, reboot, and apply again — proving it
// converges across the reboot it asked for.
fn promote(m: Machine, key: string, props: Value) -> Result[bool, string] {
    let r = m.apply_resource(key, props)?
    if r.status != "reboot_required" {
        return Err(key + ": expected reboot_required, got " + r.status + " (" + r.message + ")")
    }
    m.reboot()?
    let r2 = m.apply_resource(key, props)?
    if r2.status != "already_configured" {
        return Err(key + ": did not converge after reboot, got " + r2.status + " (" + r2.message + ")")
    }
    Ok(true)
}

// Install the AD-DS role and fail loudly if it does not converge.
fn install_role(m: Machine) -> Result[bool, string] {
    let r = m.apply_resource("windows_features.windows_server_feature", role())?
    if !r.ok {
        return Err("AD-DS role install failed: " + r.status + " (" + r.message + ")")
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

fn run(lab: Lab) -> Result[bool, string] {
    // --- dc01: new forest, serving DNS for the corp segment --------------
    lab.log("bringing up dc01 (forest root, DNS server)")
    let dc1 = lab.machine("dc01")?
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
    if !gv_bool(m1, "is_dc") || gv_str(m1, "domain") != "corp.example.com" {
        return Err("membership gatherer disagrees on dc01: domain '" + gv_str(m1, "domain") + "'")
    }
    let fsmo = gv_count(m1, "fsmo_roles")
    if fsmo != 5 {
        return Err("dc01 should hold all 5 FSMO roles, gatherer reports {fsmo}")
    }
    lab.log("dc01 is up as a DC for corp.example.com (FSMO x5)")

    // --- member01: join the domain --------------------------------------
    lab.log("bringing up member01 (member server)")
    let mem = lab.machine("member01")?
    wait_resolve(mem, "corp.example.com")?
    promote(mem, "windows_domain.domain_member",
        Value::Map(#{
            "domain_name": s("corp.example.com"),
            "credential_user": s("CORP\\Administrator"),
            "credential_password": s("vmlab123!")
        }))?
    let pm = membership(mem)?
    if !gv_bool(pm, "part_of_domain") || gv_str(pm, "role") != "member_server" {
        return Err("member01 did not join as a member server (role '" + gv_str(pm, "role") + "')")
    }
    lab.log("member01 joined corp.example.com as " + gv_str(pm, "role"))

    // --- dc02: additional DC into the existing domain -------------------
    lab.log("bringing up dc02 (additional DC)")
    let dc2 = lab.machine("dc02")?
    wait_resolve(dc2, "corp.example.com")?
    install_role(dc2)?
    promote(dc2, "windows_domain.domain_controller",
        Value::Map(#{
            "domain_name": s("corp.example.com"),
            "safe_mode_password": s("P@ssw0rd-DSRM!"),
            "credential_user": s("CORP\\Administrator"),
            "credential_password": s("vmlab123!")
        }))?
    let dcs = ad_wait(dc2, "(Get-ADDomainController -Filter *).Count", "$v -ge 2")?
    if dcs == "0" || dcs == "1" {
        return Err("dc02 did not register as a second DC (count='" + dcs + "')")
    }
    lab.log("dc02 replicated into corp.example.com")

    // --- dc-alt: a second, independent forest with explicit levels ------
    lab.log("bringing up dc-alt (second forest)")
    let alt = lab.machine("dc-alt")?
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

    // --- dc02 again: demote (ensure = :absent) -------------------------
    lab.log("demoting dc02 back out of corp.example.com")
    promote(dc2, "windows_domain.domain_controller",
        Value::Map(#{
            "domain_name": s("corp.example.com"),
            "ensure": s("absent"),
            "local_admin_password": s("vmlab123!"),
            "credential_user": s("CORP\\Administrator"),
            "credential_password": s("vmlab123!")
        }))?
    let m2 = membership(dc2)?
    if gv_bool(m2, "is_dc") {
        return Err("dc02 is still a DC after demotion (role '" + gv_str(m2, "role") + "')")
    }
    if gv_count(m2, "fsmo_roles") != 0 {
        return Err("demoted dc02 still reports FSMO roles")
    }
    lab.log("dc02 demoted (role '" + gv_str(m2, "role") + "')")

    // --- member01 again: leave the domain for a workgroup ----------------
    lab.log("moving member01 out of the domain into workgroup TESTWG")
    promote(mem, "windows_domain.workgroup_member",
        Value::Map(#{
            "workgroup_name": s("TESTWG"),
            "credential_user": s("CORP\\Administrator"),
            "credential_password": s("vmlab123!")
        }))?
    let wg = membership(mem)?
    if gv_bool(wg, "part_of_domain") || gv_str(wg, "workgroup") != "TESTWG" {
        return Err("member01 did not land in TESTWG (workgroup '" + gv_str(wg, "workgroup") + "')")
    }
    lab.log("member01 left the domain into TESTWG")

    Ok(true)
}
