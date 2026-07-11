// Scenario driver for windows_domain: drives the declared `ad-lab` VMs
// through a full AD topology across real reboots and asserts each stage.
// Run by `config-weave test` via the `testlab` host API. The VMs are
// defined in tests/ad-lab/vmlab.wcl; here we just bring each up by name and
// configure it.
//
//   dc01     forest root for corp.example.com, serves DNS  (windows_domain.forest)
//   member01 member server joining corp.example.com        (windows_domain.domain_member)
//   dc02     additional DC replicated into corp.example.com (windows_domain.domain_controller)
//   dc-alt   a second, independent forest alt.test          (windows_domain.forest)
//
// Credentials: the windows-server-2025 template's built-in Administrator is
// `vmlab123!`; after dc01 promotes, that account becomes CORP\Administrator.

use testlab
use value

// Small Value builders so the resource property maps stay readable.
fn s(v: string) -> Value { Value::String(v) }
fn b(v: bool) -> Value { Value::Bool(v) }

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
    promote(dc1, "windows_domain.forest",
        Value::Map(#{
            "domain_name": s("corp.example.com"),
            "safe_mode_password": s("P@ssw0rd-DSRM!"),
            "install_dns": b(true)
        }))?
    let d1 = ad_wait(dc1, "(Get-ADDomain).DNSRoot", "$v -eq 'corp.example.com'")?
    if d1 != "corp.example.com" {
        return Err("dc01 is not a DC for corp.example.com: '" + d1 + "'")
    }
    lab.log("dc01 is up as a DC for corp.example.com")

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
    let pm = mem.powershell("(Get-CimInstance Win32_ComputerSystem).PartOfDomain")?
    if pm.stdout.trim() != "True" {
        return Err("member01 did not join the domain: '" + pm.stdout.trim() + "'")
    }
    lab.log("member01 joined corp.example.com")

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
    promote(alt, "windows_domain.forest",
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

    Ok(true)
}
