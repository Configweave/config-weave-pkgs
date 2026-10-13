use value
use registry
use common

// WSUS settings straddle two keys: the server URLs and target group live on
// the WindowsUpdate key, while the switch that makes the client actually use
// them (UseWUServer) lives on the AU subkey.
fn wu_names() -> List[string] { ["WUServer", "WUStatusServer", "TargetGroup", "TargetGroupEnabled"] }

fn want_use_wsus(params: Value) -> Result[int, string] {
    let u = common::param_str(params, "use_wsus", "unmanaged")
    if u == "enabled" { return Ok(1) }
    if u == "disabled" { return Ok(0) }
    if u == "unmanaged" { return Ok(-1) }
    Err("invalid 'use_wsus' value '" + u + "' (expected :enabled, :disabled or :unmanaged)")
}

// An empty string means unmanaged; the status server defaults to the update
// server, which is what the GP UI does when the field is left blank. A status
// server without an update server, or switching the client to WSUS without
// naming one, would leave the policy half-configured, so both are rejected.
fn validate(params: Value) -> Result[unit, string] {
    let server = common::param_str(params, "server", "")
    if server == "" && common::param_str(params, "status_server", "") != "" {
        return Err("'status_server' requires 'server'")
    }
    if server == "" && want_use_wsus(params)? == 1 {
        return Err("use_wsus = :enabled requires 'server'")
    }
    Ok(())
}

fn status_server(params: Value) -> string {
    let s = common::param_str(params, "status_server", "")
    if s != "" { return s }
    common::param_str(params, "server", "")
}

fn absent(params: Value) -> Result[bool, string] {
    if common::want_present(params)? { return Ok(false) }
    if common::param_str(params, "server", "") != "" || common::param_str(params, "status_server", "") != "" ||
        common::param_str(params, "target_group", "") != "" || want_use_wsus(params)? != -1 {
        return Err("ensure = :absent removes the whole WSUS configuration; leave the other params unmanaged")
    }
    Ok(true)
}

fn str_matches(name: string, want: string) -> Result[bool, string] {
    if let Some(have) = common::reg_str(common::wu_key(), name)? { return Ok(have == want) }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if absent(params)? {
        if common::any_value(common::wu_key(), wu_names())? || common::has_value(common::au_key(), "UseWUServer")? {
            return Ok(CheckResult::NotConfigured)
        }
        return Ok(CheckResult::AlreadyConfigured)
    }
    validate(params)?
    let server = common::param_str(params, "server", "")
    if server != "" {
        if !str_matches("WUServer", server)? { return Ok(CheckResult::NotConfigured) }
        if !str_matches("WUStatusServer", status_server(params))? { return Ok(CheckResult::NotConfigured) }
    }
    let group = common::param_str(params, "target_group", "")
    if group != "" {
        if !str_matches("TargetGroup", group)? { return Ok(CheckResult::NotConfigured) }
        if !common::int_matches(common::wu_key(), "TargetGroupEnabled", 1)? { return Ok(CheckResult::NotConfigured) }
    }
    if !common::int_matches(common::au_key(), "UseWUServer", want_use_wsus(params)?)? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if absent(params)? {
        common::delete_values(common::wu_key(), wu_names())?
        common::delete_value(common::au_key(), "UseWUServer")?
        return Ok(ApplyResult::Success)
    }
    validate(params)?
    let server = common::param_str(params, "server", "")
    if server != "" {
        registry::create_key(common::wu_key())?
        registry::write(common::wu_key(), "WUServer", Value::String(server), "sz")?
        registry::write(common::wu_key(), "WUStatusServer", Value::String(status_server(params)), "sz")?
    }
    let group = common::param_str(params, "target_group", "")
    if group != "" {
        registry::create_key(common::wu_key())?
        registry::write(common::wu_key(), "TargetGroup", Value::String(group), "sz")?
        registry::write(common::wu_key(), "TargetGroupEnabled", Value::Int(1), "dword")?
    }
    common::put_int(common::au_key(), "UseWUServer", want_use_wsus(params)?)?
    Ok(ApplyResult::Success)
}
