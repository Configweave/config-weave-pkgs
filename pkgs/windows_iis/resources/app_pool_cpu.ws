use value
use common
use section

// ---------------------------------------------------------------------------
// An application pool's cpu element.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let pool = common::param_str(params, "pool", "")
    if pool == "" { return Err("missing 'pool' parameter") }
    Ok("system.applicationHost/applicationPools/add[@name='" + common::xp(pool)? + "']")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["limit", "cpu.limit", "int"],
        ["action", "cpu.action", "sym"],
        ["reset_interval", "cpu.resetInterval", "dur"],
        ["smp_affinitized", "cpu.smpAffinitized", "bool"],
        ["smp_processor_affinity_mask", "cpu.smpProcessorAffinityMask", "int"],
        ["smp_processor_affinity_mask2", "cpu.smpProcessorAffinityMask2", "int"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["action", "no_action", "NoAction"],
        ["action", "kill_w3wp", "KillW3wp"],
        ["action", "throttle", "Throttle"],
        ["action", "throttle_under_load", "ThrottleUnderLoad"],
    ] }

fn spec(params: Value) -> Result[SectionSpec, string] {
    Ok(SectionSpec { filter: section(params)?, scope: scope(params)?, attrs: attrs(), syms: sym_map(), extra: [] })
}

fn check(params: Value) -> Result[CheckResult, string] {
    section::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    section::apply(params, spec(params)?)?
    Ok(ApplyResult::Success)
}
