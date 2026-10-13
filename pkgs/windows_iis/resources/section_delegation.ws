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
    // Inherit clears an explicit setting so the parent's takes effect again.
    // IIS accepts only Allow, Deny or Inherit here; the empty string is a
    // schema error.
    if m == "inherit" { return Ok("Inherit") }
    Err("invalid 'override_mode' value '" + m + "' (expected :allow, :deny or :inherit)")
}

// The overrideMode set explicitly for the section at this location, or
// "Inherit". Get-WebConfiguration -Metadata cannot answer this: its
// overrideMode reads "Inherit" even straight after Allow was written, and its
// effectiveOverrideMode folds in the parents. The setting lives on a
// <location path="..." overrideMode="..."> wrapping the section in
// applicationHost.config, so that is where it is read.
fn current(params: Value) -> Result[string, string] {
    let loc = common::xp(common::param_str(params, "location", ""))?
    let sec = filter(params)?
    let locs = if loc == "" { "location[not(@path) or @path='']" } else { "location[@path='" + loc + "']" }
    common::ps_out(
        "$x = New-Object xml; $x.Load((Join-Path $env:windir 'system32\\inetsrv\\config\\applicationHost.config')); " +
        "$m = 'Inherit'; foreach ($l in @($x.SelectNodes(" + common::ps_q("/configuration/" + locs + "[@overrideMode]") + "))) {{ " +
        "if ($null -ne $l.SelectSingleNode(" + common::ps_q("." + sec) + ")) {{ $m = $l.GetAttribute('overrideMode') }} }}; $m")
}

fn check(params: Value) -> Result[CheckResult, string] {
    if current(params)?.to_lower() == override_mode(params)?.to_lower() {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let want = override_mode(params)?
    if current(params)?.to_lower() == want.to_lower() { return Ok(ApplyResult::Success) }
    log::info("delegation of " + common::param_str(params, "section_path", "") + " = " + want)
    common::ps_run("Set-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST'" + location_arg(params) +
        " -Filter " + common::ps_q(filter(params)?) + " -Metadata 'overrideMode' -Value " + common::ps_q(want))?
    Ok(ApplyResult::Success)
}
