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
//
// ensure = :absent deletes the attribute at this level, so the value is
// inherited again — the one thing the typed resources cannot do.
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

// The name is spliced into PowerShell unquoted ($s.<name>), so it is held to
// the characters an IIS attribute name can have.
fn attribute(params: Value) -> Result[string, string] {
    common::attr_name("name", common::param_str(params, "name", ""))
}

// A value that must not reach the log or the script text: secret = true, or
// any attribute whose name says it is a password.
fn secret(params: Value) -> Result[bool, string] {
    if common::param_bool(params, "secret", false) { return Ok(true) }
    Ok(attribute(params)?.to_lower().contains("password"))
}

fn shown(params: Value) -> Result[string, string] {
    if secret(params)? { return Ok("********") }
    Ok(common::param_str(params, "value", ""))
}

// Whether the attribute is written at this level — in the <location> (or the
// web.config) the step names, rather than inherited. Answered from the file
// itself: no configuration API says where an attribute's value came from.
// The filter is already an XPath relative to <configuration>, so the
// attribute is found by extending it: processModel.identityType under
// system.applicationHost/applicationPools/add[@name='p'] becomes
// .../add[@name='p']/processModel/@identityType.
fn attr_xpath(params: Value) -> Result[string, string] {
    let f = filter(params)?
    if f.starts_with("/") { f = f.slice(1, f.len()) }
    let parts = attribute(params)?.split(".")
    let out = f
    let i = 0
    while i < parts.len() - 1 { out = out + "/" + parts.get(i).unwrap_or(""); i = i + 1 }
    Ok(out + "/@" + parts.get(parts.len() - 1).unwrap_or(""))
}

fn locally_set(params: Value) -> Result[bool, string] {
    let site = common::param_str(params, "site", "")
    let path = common::param_str(params, "path", "")
    let tail = attr_xpath(params)?
    let file = ""
    let roots: List[string] = []
    if common::param_str(params, "store", "apphost") == "web_config" {
        if site == "" { return Err("store = :web_config needs a 'site'") }
        let rel = path.replace("/", "\\")
        file = "$p = (Get-WebFilePath " + common::ps_q("IIS:\\Sites\\" + site + rel) + ").FullName; $file = Join-Path $p 'web.config'; "
        roots.push("/configuration/")
    } else {
        file = "$file = Join-Path $env:windir 'system32\\inetsrv\\config\\applicationHost.config'; "
        if site == "" {
            roots.push("/configuration/")
            roots.push("/configuration/location[@path='']/")
        } else {
            roots.push("/configuration/location[@path='" + common::xp(site + path)? + "']/")
        }
    }
    let tests: List[string] = []
    for r in roots { tests.push("$x.SelectNodes(" + common::ps_q(r + tail) + ").Count") }
    let out = common::ps_out(file +
        "if (-not (Test-Path -LiteralPath $file)) {{ 'NO' }} else {{ $x = New-Object xml; $x.Load($file); " +
        "if ((" + tests.join(" + ") + ") -gt 0) {{ 'YES' }} else {{ 'NO' }} }}")?
    Ok(out == "YES")
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
    if !common::want_present(params)? {
        if locally_set(params)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // Fail on an unusable value_type here rather than at apply time, so a
    // dry run reports it.
    ps_value(params)?
    if same(current(params)?, common::param_str(params, "value", "")) {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if !common::want_present(params)? {
        if !locally_set(params)? { return Ok(ApplyResult::Success) }
        log::info("removing " + filter(params)? + " " + attribute(params)? + " at this level")
        // Clear-WebConfiguration on an attribute XPath deletes that one
        // attribute, so the value is inherited again; Remove-
        // WebConfigurationProperty only reaches collection entries.
        common::ps_run("Clear-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
            common::ps_q(attr_xpath(params)?))?
        return Ok(ApplyResult::Success)
    }
    let value = ps_value(params)?
    if same(current(params)?, common::param_str(params, "value", "")) { return Ok(ApplyResult::Success) }
    log::info("setting " + filter(params)? + " " + attribute(params)? + " = " + shown(params)?)
    let set = "Set-WebConfigurationProperty" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(filter(params)?) + " -Name " + common::ps_q(attribute(params)?) + " -Value "
    if secret(params)? && value_type(params)? == "string" {
        common::ps_run_env(set + "$env:CW_SECRET", common::secret_env(common::param_str(params, "value", "")))?
    } else {
        common::ps_run(set + value)?
    }
    Ok(ApplyResult::Success)
}
