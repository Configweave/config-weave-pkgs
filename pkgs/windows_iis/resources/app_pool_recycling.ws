use value
use common
use section

// ---------------------------------------------------------------------------
// An application pool's recycling element. The wall-clock schedule is an
// ordered collection, so an empty list clears it.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let pool = common::param_str(params, "pool", "")
    if pool == "" { return Err("missing 'pool' parameter") }
    Ok("system.applicationHost/applicationPools/add[@name='" + common::xp(pool)? + "']")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["disallow_overlapping_rotation", "recycling.disallowOverlappingRotation", "bool"],
        ["disallow_rotation_on_config_change", "recycling.disallowRotationOnConfigChange", "bool"],
        ["log_event_on_recycle", "recycling.logEventOnRecycle", "flags"],
        ["periodic_restart_time", "recycling.periodicRestart.time", "dur"],
        ["periodic_restart_memory", "recycling.periodicRestart.memory", "int"],
        ["periodic_restart_private_memory", "recycling.periodicRestart.privateMemory", "int"],
        ["periodic_restart_requests", "recycling.periodicRestart.requests", "int"],
        ["schedule", "recycling.periodicRestart.schedule", "vlist"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

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
