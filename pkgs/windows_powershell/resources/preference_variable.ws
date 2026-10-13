use value
use common
use profiles

// Not a mechanical PascalCase of the symbol: several of these carry a PS
// prefix ($PSModuleAutoLoadingPreference) that the symbol name does not.
fn variable_name(symbol: string) -> Result[string, string] {
    let table = #{
        "confirm_preference": "ConfirmPreference",
        "debug_preference": "DebugPreference",
        "error_action_preference": "ErrorActionPreference",
        "error_view": "ErrorView",
        "information_preference": "InformationPreference",
        "progress_preference": "ProgressPreference",
        "verbose_preference": "VerbosePreference",
        "warning_preference": "WarningPreference",
        "whatif_preference": "WhatIfPreference",
        "module_autoloading_preference": "PSModuleAutoLoadingPreference",
        "maximum_history_count": "MaximumHistoryCount",
        "output_encoding": "OutputEncoding",
        "native_command_argument_passing": "PSNativeCommandArgumentPassing",
        "native_command_use_error_action_preference": "PSNativeCommandUseErrorActionPreference",
        "style": "PSStyle",
        "default_parameter_values": "PSDefaultParameterValues",
        "session_option": "PSSessionOption",
        "email_server": "PSEmailServer",
        "transcript": "Transcript"
    }
    if let Some(name) = table.get(symbol) { return Ok(name) }
    Err("unknown preference variable '" + symbol + "'")
}

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
    let symbol = common::param_str(params, "name", "")
    if symbol == "" { return Err("missing 'name' parameter") }
    Ok("preference-" + symbol.replace("_", "-"))
}

fn desired_body(params: Value) -> Result[string, string] {
    let symbol = common::param_str(params, "name", "")
    if symbol == "" { return Err("missing 'name' parameter") }
    Ok("$" + variable_name(symbol)? + " = " + render_value(params)?)
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
