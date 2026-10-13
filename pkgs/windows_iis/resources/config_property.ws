use value
use log
use common

// ---------------------------------------------------------------------------
// The untyped escape hatch for a single attribute, the way git.config_entry
// reaches the git variables the typed section resources do not name.
//
// IIS's schema is far larger than this package models, and it rejects a
// string where it wants a number or a flag — hence value_type. A duration is
// written in IIS's own "HH:MM:SS" spelling rather than as a WCL duration,
// because this resource does not know which attributes are TimeSpans.
// ---------------------------------------------------------------------------

fn value_type(params: Value) -> Result[string, string] {
    let t = common::param_str(params, "value_type", "string")
    if t == "string" || t == "int" || t == "bool" { return Ok(t) }
    Err("invalid 'value_type' value '" + t + "' (expected :string, :int or :bool)")
}

fn ps_value(params: Value) -> Result[string, string] {
    let t = value_type(params)?
    let v = common::param_str(params, "value", "")
    if t == "bool" {
        let low = v.to_lower()
        if low == "true" { return Ok("$true") }
        if low == "false" { return Ok("$false") }
        return Err("value '" + v + "' is not true or false, but value_type is :bool")
    }
    if t == "int" {
        if v.parse_int().is_none() {
            return Err("value '" + v + "' is not an integer, but value_type is :int")
        }
        return Ok(v)
    }
    Ok(common::ps_q(v))
}

fn filter(params: Value) -> Result[string, string] {
    let f = common::param_str(params, "filter", "")
    if f == "" { return Err("missing 'filter' parameter") }
    Ok(f)
}

fn attribute(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    if n == "" { return Err("missing 'name' parameter") }
    Ok(n)
}

// Through the section element so an enum attribute reads as its schema name
// rather than as a number, and guarded so a site-scoped location that does not
// exist yet reports drift instead of failing the check.
fn current(params: Value) -> Result[string, string] {
    common::ps_out("$s=$null; try {{ $s = Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(filter(params)?) + " }} catch {{ }}; " +
        "if ($null -eq $s) {{ '' }} else {{ CwV($s." + attribute(params)? + ") }}")
}

// Booleans come back as true/false whatever their spelling went in as, and a
// flags attribute comes back with IIS's own capitalisation, so the comparison
// is case-insensitive and blind to the spaces IIS puts after its commas.
fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
}

fn check(params: Value) -> Result[CheckResult, string] {
    // Fail on an unusable value_type here rather than at apply time, so a
    // dry run reports it.
    ps_value(params)?
    if same(current(params)?, common::param_str(params, "value", "")) {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let value = ps_value(params)?
    if same(current(params)?, common::param_str(params, "value", "")) { return Ok(ApplyResult::Success) }
    log::info("setting " + filter(params)? + " " + attribute(params)? + " = " +
        common::param_str(params, "value", ""))
    common::ps_run("Set-WebConfigurationProperty" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(filter(params)?) + " -Name " + common::ps_q(attribute(params)?) + " -Value " + value)?
    Ok(ApplyResult::Success)
}
