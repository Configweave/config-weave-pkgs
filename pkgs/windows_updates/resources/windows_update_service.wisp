use value
use service

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

// The Windows Update service. `wuauserv` is "manual" (trigger-started) by
// default; disabling it stops automatic servicing entirely.
fn svc() -> string { "wuauserv" }

fn check(params: Value) -> Result[CheckResult, string] {
    let startup = service::startup(svc())?
    if param_bool(params, "enabled", true) {
        // Enabled = not disabled (manual/trigger or automatic both count).
        if startup != "disabled" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
    } else {
        // Disabled = startup disabled and the service stopped.
        if startup == "disabled" && service::status(svc())? == "stopped" {
            Ok(CheckResult::AlreadyConfigured)
        } else {
            Ok(CheckResult::NotConfigured)
        }
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if param_bool(params, "enabled", true) {
        service::set_startup(svc(), "manual")?
    } else {
        service::set_startup(svc(), "disabled")?
        service::stop(svc())?
    }
    Ok(ApplyResult::Success)
}
