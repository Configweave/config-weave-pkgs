use value
use json
use log
use common

// ---------------------------------------------------------------------------
// The application pool itself: its existence, its runtime state, and the
// attributes on the pool element and its processModel child. The recycling,
// failure and cpu children are their own resources, so a playbook that only
// wants a nightly recycle does not have to restate the pool's identity.
//
// The attribute half below is the same read-diff-write the section resources
// in this package use; it is repeated rather than shared because wscript has
// no script-to-script imports yet.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    Ok("system.applicationHost/applicationPools/add[@name='" + common::xp(name)? + "']")
}

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["auto_start", "autoStart", "bool"],
        ["managed_runtime_version", "managedRuntimeVersion", "sym"],
        ["managed_pipeline_mode", "managedPipelineMode", "sym"],
        ["enable_32bit", "enable32BitAppOnWin64", "bool"],
        ["start_mode", "startMode", "sym"],
        ["queue_length", "queueLength", "int"],
        ["enable_configuration_override", "enableConfigurationOverride", "bool"],
        ["identity_type", "processModel.identityType", "sym"],
        ["username", "processModel.userName", "str"],
        ["password", "processModel.password", "str"],
        ["idle_timeout", "processModel.idleTimeout", "dur"],
        ["idle_timeout_action", "processModel.idleTimeoutAction", "sym"],
        ["max_processes", "processModel.maxProcesses", "int"],
        ["load_user_profile", "processModel.loadUserProfile", "bool"],
        ["set_profile_environment", "processModel.setProfileEnvironment", "bool"],
        ["ping_enabled", "processModel.pingingEnabled", "bool"],
        ["ping_interval", "processModel.pingInterval", "dur"],
        ["ping_response_time", "processModel.pingResponseTime", "dur"],
        ["startup_time_limit", "processModel.startupTimeLimit", "dur"],
        ["shutdown_time_limit", "processModel.shutdownTimeLimit", "dur"],
        ["logon_type", "processModel.logonType", "sym"],
        ["manual_group_membership", "processModel.manualGroupMembership", "bool"],
    ] }

// :none is the empty string IIS stores for "No Managed Code" — the one symbol
// here whose token is not a word.
fn sym_map() -> List[List[string]] { [
        ["managed_runtime_version", "none", ""],
        ["managed_runtime_version", "v1_1", "v1.1"],
        ["managed_runtime_version", "v2_0", "v2.0"],
        ["managed_runtime_version", "v4_0", "v4.0"],
        ["managed_pipeline_mode", "integrated", "Integrated"],
        ["managed_pipeline_mode", "classic", "Classic"],
        ["start_mode", "on_demand", "OnDemand"],
        ["start_mode", "always_running", "AlwaysRunning"],
        ["identity_type", "application_pool_identity", "ApplicationPoolIdentity"],
        ["identity_type", "local_service", "LocalService"],
        ["identity_type", "local_system", "LocalSystem"],
        ["identity_type", "network_service", "NetworkService"],
        ["identity_type", "specific_user", "SpecificUser"],
        ["idle_timeout_action", "terminate", "Terminate"],
        ["idle_timeout_action", "suspend", "Suspend"],
        ["logon_type", "batch", "LogonBatch"],
        ["logon_type", "service", "LogonService"],
    ] }

fn iis_symbol(name: string, v: string) -> string {
    for row in sym_map() {
        if row.get(0).unwrap_or("") == name && row.get(1).unwrap_or("") == v {
            return row.get(2).unwrap_or("")
        }
    }
    v
}

fn desired(params: Value, name: string, kind: string) -> Option[string] {
    if !common::has(params, name) { return None }
    if kind == "bool" {
        if common::param_bool(params, name, false) { return Some("true") }
        return Some("false")
    }
    if kind == "int" { return Some(common::itoa(common::param_int(params, name, 0))) }
    if kind == "dur" { return Some(common::hms(common::param_int(params, name, 0))) }
    let raw = common::param_str(params, name, "")
    if raw == "" { return None }
    if kind == "sym" { return Some(iis_symbol(name, raw)) }
    Some(raw)
}

fn wanted(params: Value) -> List[List[string]] {
    let out: List[List[string]] = []
    for a in attrs() {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        if let Some(text) = desired(params, name, kind) {
            out.push([name, a.get(1).unwrap_or(""), kind, text])
        }
    }
    out
}

fn same(kind: string, have: string, want: string) -> bool {
    if kind == "bool" || kind == "sym" {
        return have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
    }
    have == want
}

fn ps_value(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    if kind == "int" { return want }
    common::ps_q(want)
}

// Read through the pool element rather than Get-WebConfigurationProperty:
// identityType, managedPipelineMode, startMode, idleTimeoutAction and
// logonType are all enums, and the property cmdlet hands back their raw
// numbers while the provider renders the schema name as a property.
fn probe_attrs(params: Value, rows: List[List[string]]) -> Result[Value, string] {
    let filter = common::ps_q(section(params)?)
    let reads = ""
    for r in rows {
        let name = common::ps_q(r.get(0).unwrap_or(""))
        reads = reads + "$o[" + name + "]=''; try {{ $o[" + name + "]=CwV($s." +
            r.get(1).unwrap_or("") + ") }} catch {{ }}; "
    }
    json::parse(common::ps_out(
        "$o=@{{}}; $s=$null; try {{ $s = Get-WebConfiguration " +
        "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + filter + " }} catch {{ }}; " +
        "if ($null -ne $s) {{ " + reads + "}}; " +
        "[pscustomobject]$o | ConvertTo-Json -Compress")?)
}

fn exists(name: string) -> Result[bool, string] {
    let st = common::ps_out("if (Test-Path (Join-Path 'IIS:\\AppPools' " + common::ps_q(name) +
        ")) {{ 'YES' }} else {{ 'NO' }}")?
    Ok(st == "YES")
}

// Started | Stopped | Starting | Stopping | Unknown.
fn pool_state(name: string) -> Result[string, string] {
    common::ps_out("(Get-WebAppPoolState -Name " + common::ps_q(name) + ").Value")
}

fn desired_state(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "state", "unmanaged")
    if s == "started" || s == "stopped" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'state' value '" + s + "' (expected :started, :stopped or :unmanaged)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let there = exists(name)?
    if !common::want_present(params)? {
        if there { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !there { return Ok(CheckResult::NotConfigured) }
    let rows = wanted(params)
    if !rows.is_empty() {
        let have = probe_attrs(params, rows)?
        for r in rows {
            if !same(r.get(2).unwrap_or(""), common::get_str(have, r.get(0).unwrap_or("")),
                     r.get(3).unwrap_or("")) {
                return Ok(CheckResult::NotConfigured)
            }
        }
    }
    let st = desired_state(params)?
    // A pool mid-transition counts as not yet configured; apply nudges it.
    if st != "unmanaged" && pool_state(name)?.to_lower() != st { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = common::ps_q(name)
    if !common::want_present(params)? {
        if !exists(name)? { return Ok(ApplyResult::Success) }
        log::info("removing application pool " + name)
        common::ps_run("Remove-WebAppPool -Name " + qn)?
        return Ok(ApplyResult::Success)
    }
    if !exists(name)? {
        log::info("creating application pool " + name)
        common::ps_run("New-WebAppPool -Name " + qn + " | Out-Null")?
    }
    let rows = wanted(params)
    if !rows.is_empty() {
        let have = probe_attrs(params, rows)?
        let filter = common::ps_q(section(params)?)
        let script = ""
        for r in rows {
            let attr = r.get(1).unwrap_or("")
            let kind = r.get(2).unwrap_or("")
            let want = r.get(3).unwrap_or("")
            if same(kind, common::get_str(have, r.get(0).unwrap_or("")), want) { continue }
            log::info("setting " + name + " " + attr)
            script = script +
                "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                filter + " -Name " + common::ps_q(attr) + " -Value " + ps_value(kind, want) + "; "
        }
        if script != "" { common::ps_run(script)? }
    }
    let st = desired_state(params)?
    if st != "unmanaged" && pool_state(name)?.to_lower() != st {
        if st == "started" {
            common::ps_run("Start-WebAppPool -Name " + qn)?
        } else {
            common::ps_run("Stop-WebAppPool -Name " + qn)?
        }
    }
    Ok(ApplyResult::Success)
}
