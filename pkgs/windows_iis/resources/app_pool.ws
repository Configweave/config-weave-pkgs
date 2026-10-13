use value
use json
use log
use common
use section

// ---------------------------------------------------------------------------
// The application pool itself: its existence, its runtime state, and the
// attributes on the pool element and its processModel child. The recycling,
// failure and cpu children are their own resources, so a playbook that only
// wants a nightly recycle does not have to restate the pool's identity.
//
// The attribute half is the section machinery in lib/section.ws, run over the
// pool's own element; the password is a secret attribute, passed through the
// environment and masked in the log.
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
        ["password", "processModel.password", "secret"],
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

fn spec(params: Value) -> Result[SectionSpec, string] {
    Ok(SectionSpec { filter: section(params)?, scope: common::scope_apphost(params)?, attrs: attrs(), syms: sym_map(), extra: [] })
}

// Looked up through ServerManager rather than IIS:\AppPools or
// Get-WebAppPoolState, whose names are wildcard patterns: [, ], * and ? in a
// pool name would match other pools, or fail to match this one.
fn exists(name: string) -> Result[bool, string] {
    let st = common::ps_out("if ($null -ne (CwSm).ApplicationPools[" + common::ps_q(name) +
        "]) {{ 'YES' }} else {{ 'NO' }}")?
    Ok(st == "YES")
}

// Started | Stopped | Starting | Stopping | Unknown.
fn pool_state(name: string) -> Result[string, string] {
    common::ps_out("$p = (CwSm).ApplicationPools[" + common::ps_q(name) + "]; " +
        "try {{ [string]$p.State }} catch {{ 'Unknown' }}")
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
    if section::check(params, spec(params)?)? == CheckResult::NotConfigured {
        return Ok(CheckResult::NotConfigured)
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
        common::ps_run("$sm = CwSm; $sm.ApplicationPools.Remove($sm.ApplicationPools[" + qn + "]); $sm.CommitChanges()")?
        return Ok(ApplyResult::Success)
    }
    if !exists(name)? {
        log::info("creating application pool " + name)
        common::ps_run("Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' " +
            "-Filter 'system.applicationHost/applicationPools' -Name '.' -Value @{{name=" + qn + "}}")?
    }
    section::apply(params, spec(params)?)?
    let st = desired_state(params)?
    if st != "unmanaged" && pool_state(name)?.to_lower() != st {
        let verb = if st == "started" { "Start" } else { "Stop" }
        common::ps_run("[void](CwSm).ApplicationPools[" + qn + "]." + verb + "()")?
    }
    Ok(ApplyResult::Success)
}
