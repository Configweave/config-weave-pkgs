use value
use log
use common

// ---------------------------------------------------------------------------
// The "SSL Settings" page: system.webServer/security/access sslFlags.
//
// IIS stores one comma-separated flags attribute, but a playbook thinks in
// three independent switches, so this reads the current flags, replaces only
// the bits the step named, and writes the set back. A step that mentions
// require_ssl therefore does not silently clear an inherited SslRequireCert.
// ---------------------------------------------------------------------------

fn section() -> string { "system.webServer/security/access" }

fn flag_set(text: string) -> List[string] {
    let out: List[string] = []
    for p in text.split(",") {
        let f = p.trim()
        if f != "" && f.to_lower() != "none" { out.push(f) }
    }
    out
}

fn without(flags: List[string], drop: string) -> List[string] {
    let out: List[string] = []
    for f in flags { if f.to_lower() != drop.to_lower() { out.push(f) } }
    out
}

fn client_certificates(params: Value) -> Result[string, string] {
    let v = common::param_str(params, "client_certificates", "")
    if v == "" { return Ok("") }
    if v == "ignore" || v == "accept" || v == "require" { return Ok(v) }
    Err("invalid 'client_certificates' value '" + v + "'")
}

// The flags the step wants, folded into whatever is already there.
fn wanted_flags(params: Value, current: string) -> Result[string, string] {
    let flags = flag_set(current)
    if common::has(params, "require_ssl") {
        flags = without(flags, "Ssl")
        if common::param_bool(params, "require_ssl", false) { flags.push("Ssl") }
    }
    if common::has(params, "require_128bit") {
        flags = without(flags, "Ssl128")
        if common::param_bool(params, "require_128bit", false) { flags.push("Ssl128") }
    }
    let cc = client_certificates(params)?
    if cc != "" {
        // SslRequireCert only means anything alongside SslNegotiateCert, so
        // the two move together.
        flags = without(without(flags, "SslNegotiateCert"), "SslRequireCert")
        if cc == "accept" { flags.push("SslNegotiateCert") }
        if cc == "require" {
            flags.push("SslNegotiateCert")
            flags.push("SslRequireCert")
        }
    }
    if flags.is_empty() { return Ok("None") }
    flags.sort()
    Ok(flags.join(","))
}

// Through the section element, not Get-WebConfigurationProperty: the cmdlet
// hands back the raw flags number ("0"), which would then be folded into the
// set as if it were a flag name and rejected by the schema. Guarded because a
// -Location for a site that does not exist yet cannot be read at all.
fn current_flags(params: Value) -> Result[string, string] {
    common::ps_out("$s=$null; try {{ $s = Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(section()) + " }} catch {{ }}; " +
        "if ($null -eq $s) {{ 'None' }} else {{ CwV($s.sslFlags) }}")
}

fn normalized(text: string) -> string {
    let flags = flag_set(text)
    if flags.is_empty() { return "None" }
    let lower: List[string] = []
    for f in flags { lower.push(f.to_lower()) }
    lower.sort()
    lower.join(",")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let now = current_flags(params)?
    if normalized(now) == normalized(wanted_flags(params, now)?) {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let now = current_flags(params)?
    let want = wanted_flags(params, now)?
    if normalized(now) == normalized(want) { return Ok(ApplyResult::Success) }
    log::info("setting sslFlags = " + want)
    common::ps_run("Set-WebConfigurationProperty" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(section()) + " -Name 'sslFlags' -Value " + common::ps_q(want))?
    Ok(ApplyResult::Success)
}
