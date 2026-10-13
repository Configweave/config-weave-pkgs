use value
use common
use section

// ---------------------------------------------------------------------------
// An application pool's failure element.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let pool = common::param_str(params, "pool", "")
    if pool == "" { return Err("missing 'pool' parameter") }
    Ok("system.applicationHost/applicationPools/add[@name='" + common::xp(pool)? + "']")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["rapid_fail_protection", "failure.rapidFailProtection", "bool"],
        ["rapid_fail_protection_interval", "failure.rapidFailProtectionInterval", "dur"],
        ["rapid_fail_protection_max_crashes", "failure.rapidFailProtectionMaxCrashes", "int"],
        ["load_balancer_capabilities", "failure.loadBalancerCapabilities", "sym"],
        ["orphan_worker_process", "failure.orphanWorkerProcess", "bool"],
        ["orphan_action_exe", "failure.orphanActionExe", "str"],
        ["orphan_action_params", "failure.orphanActionParams", "str"],
        ["auto_shutdown_exe", "failure.autoShutdownExe", "str"],
        ["auto_shutdown_params", "failure.autoShutdownParams", "str"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["load_balancer_capabilities", "http_level", "HttpLevel"],
        ["load_balancer_capabilities", "tcp_level", "TcpLevel"],
    ] }

fn spec(params: Value) -> Result[SectionSpec, string] {
    Ok(SectionSpec { filter: section(params)?, scope: scope(params)?, attrs: attrs(), syms: sym_map() })
}

fn check(params: Value) -> Result[CheckResult, string] {
    section::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    section::apply(params, spec(params)?)?
    Ok(ApplyResult::Success)
}
