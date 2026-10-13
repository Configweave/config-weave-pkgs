use value
use common
use profiles

fn slug(s: string) -> string {
    let out = s.to_lower()
    for bad in [":", "+", ",", "*", " ", "\\", "/", "$", "'", "\"", "#"] {
        out = out.replace(bad, "-")
    }
    out
}

// Shared by default_parameter_values and preference_variable: how a string
// param becomes a PowerShell literal.
fn render_value(params: Value) -> Result[string, string] {
    let raw = common::param_str(params, "value", "")
    let kind = common::param_str(params, "value_type", "string")
    if kind == "string" { return Ok(common::ps_q(raw)) }
    if kind == "raw" { return Ok(raw) }
    if kind == "bool" {
        let normal = raw.trim().to_lower()
        if normal == "true" { return Ok("$true") }
        if normal == "false" { return Ok("$false") }
        return Err("value_type :bool needs true or false, got '" + raw + "'")
    }
    if kind == "int" {
        if raw.trim().parse_int().is_none() { return Err("value_type :int needs a whole number, got '" + raw + "'") }
        return Ok(raw.trim())
    }
    Err("unknown 'value_type' '" + kind + "'")
}

fn block_name(params: Value) -> Result[string, string] {
    let key = common::param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    Ok("defaultparam-" + slug(key))
}

fn desired_body(params: Value) -> Result[string, string] {
    let key = common::param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    Ok("$PSDefaultParameterValues[" + common::ps_q(key) + "] = " + render_value(params)?)
}

fn body(params: Value) -> Result[Option[string], string] {
    if common::want_present(params)? { return Ok(Some(desired_body(params)?)) }
    Ok(None)
}

fn check(params: Value) -> Result[CheckResult, string] {
    profiles::check_block(params, block_name(params)?, body(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    profiles::apply_block(params, block_name(params)?, body(params)?)
}
