use value
use common
use profiles

fn desired_body(params: Value) -> string {
    common::param_str(params, "content", "").trim_end()
}

fn block_name(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::require("name", name)?
    common::single_line("name", name)?
    Ok(name)
}

fn body(params: Value) -> Result[Option[string], string] {
    if common::want_present(params)? { return Ok(Some(desired_body(params))) }
    Ok(None)
}

fn check(params: Value) -> Result[CheckResult, string] {
    profiles::check_block(params, block_name(params)?, body(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    profiles::apply_block(params, block_name(params)?, body(params)?)
}
