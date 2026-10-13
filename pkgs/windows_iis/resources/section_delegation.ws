use value
use log
use common

// ---------------------------------------------------------------------------
// Feature delegation: a section's overrideMode, which is what decides whether
// a lower-level web.config may set it.
//
// This is metadata on the section rather than an attribute in it, so it is
// read and written with -Metadata rather than the usual property cmdlets.
// Most of this package writes to applicationHost.config under a <location>
// precisely so it does not need the section unlocked; this resource is for
// the applications that ship their own web.config and expect to win.
// ---------------------------------------------------------------------------

fn filter(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "section_path", "")
    if s == "" { return Err("missing 'section_path' parameter") }
    // -Metadata wants the section as an absolute configuration path.
    if s.starts_with("/") { return Ok(s) }
    Ok("/" + s)
}

fn location_arg(params: Value) -> string {
    let loc = common::param_str(params, "location", "")
    if loc == "" { return "" }
    " -Location " + common::ps_q(loc)
}

fn override_mode(params: Value) -> Result[string, string] {
    let m = common::param_str(params, "override_mode", "allow")
    if m == "allow" { return Ok("Allow") }
    if m == "deny" { return Ok("Deny") }
    // Inherit is spelled as the empty string in configuration, which is what
    // clears an explicit setting so the parent's takes effect again.
    if m == "inherit" { return Ok("") }
    Err("invalid 'override_mode' value '" + m + "' (expected :allow, :deny or :inherit)")
}

fn current(params: Value) -> Result[string, string] {
    common::ps_out("$m = Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST'" +
        location_arg(params) + " -Filter " + common::ps_q(filter(params)?) + " -Metadata; " +
        "[string]$m.Metadata.overrideMode")
}

fn check(params: Value) -> Result[CheckResult, string] {
    if current(params)?.to_lower() == override_mode(params)?.to_lower() {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let want = override_mode(params)?
    log::info("delegation of " + common::param_str(params, "section_path", "") + " = " +
        (if want == "" { "Inherit" } else { want }))
    common::ps_run("Set-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST'" + location_arg(params) +
        " -Filter " + common::ps_q(filter(params)?) + " -Metadata 'overrideMode' -Value " + common::ps_q(want))?
    Ok(ApplyResult::Success)
}
