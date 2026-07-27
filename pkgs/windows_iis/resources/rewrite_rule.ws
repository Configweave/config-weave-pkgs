use value
use shell
use json
use log
use fs
use http
use registry

// ---------------------------------------------------------------------------
// Shared IIS helpers — byte-identical in every script in this package.
//
// wscript has no script-to-script imports yet (config-weave compiles `lib/`
// but cannot resolve it), so this block is duplicated rather than shared.
// Keep the copies identical; moving to lib/ is then a mechanical delete.
//
// Everything goes through PowerShell's WebAdministration module rather than
// editing applicationHost.config directly. IIS owns the schema validation,
// the collection merge semantics and the config file locking, none of which a
// hand-rolled XML writer gets right. The cost is that the target needs the
// IIS management scripting tools (the :scripting_tools role service).
// ---------------------------------------------------------------------------

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let items: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs { if let Some(s) = x.as_string() { items.push(s) } }
        }
    }
    items
}

// A param the step omitted is absent from the map, and that absence means
// "leave this setting alone" — the only way a bool or int param can say so,
// since a declared default would instead mean "set it to false" / "set it to
// 0".
fn has(params: Value, key: string) -> bool {
    if let Some(v) = params.get(key) { return !v.is_null() }
    false
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn itoa(n: int) -> string { json::to_string(Value::Int(n)) }

fn pad2(n: int) -> string {
    let s = itoa(n)
    if s.len() < 2 { return "0" + s }
    s
}

// A duration param arrives as base nanoseconds. IIS stores a TimeSpan and
// hands it back through .NET's default format, which is "[d.]hh:mm:ss" — a day
// or more gets a leading "1." and the hours restart. Emitting a bare
// "29:00:00" therefore never compares equal to the "1.05:00:00" that comes
// back, and the attribute re-applies for ever. IIS's own default pool
// recycling interval is 29 hours, so this is a real case, not a corner one.
fn hms(ns: int) -> string {
    let secs = ns / 1000000000
    let days = secs / 86400
    let rest = secs % 86400
    let clock = pad2(rest / 3600) + ":" + pad2((rest % 3600) / 60) + ":" + pad2(rest % 60)
    if days > 0 { return itoa(days) + "." + clock }
    clock
}

// Import-Module is explicit so a machine without the scripting tools fails
// with "the specified module was not loaded" rather than "the term
// Get-WebConfigurationProperty is not recognized". CwV flattens whatever a
// configuration read hands back — a ConfigurationAttribute, a raw value, a
// TimeSpan or a flags enum — into the text this package compares against.
fn ps_head() -> string {
    "$ErrorActionPreference='Stop'; Import-Module WebAdministration; " +
    "function CwV($x) {{ " +
    "if ($null -eq $x) {{ return '' }}; " +
    "if ($x.PSObject.Properties.Name -contains 'Value') {{ $x = $x.Value }}; " +
    "if ($null -eq $x) {{ return '' }}; " +
    "if ($x -is [bool]) {{ if ($x) {{ return 'true' }} else {{ return 'false' }} }}; " +
    "if ($x -is [timespan]) {{ return $x.ToString() }}; " +
    "return ([string]$x) }}; " +
    "function CwEnum($el, $name, $fallback) {{ try {{ " +
    "$v = $el.GetAttributeValue($name); " +
    "$sch = $el.Schema.AttributeSchemas[$name]; " +
    "if ($null -ne $sch) {{ foreach ($ev in $sch.EnumValues) {{ " +
    "if ([int]$ev.Value -eq [int]$v) {{ return [string]$ev.Name }} }} }} " +
    "}} catch {{ }}; return $fallback }}; "
}

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell(ps_head() + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell(ps_head() + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

// -PSPath and -Location for a delegated section. Writing to
// MACHINE/WEBROOT/APPHOST under a -Location is the PowerShell spelling of
// appcmd's /commit:apphost: it reaches a section that is locked against
// web.config, which every system.webServer/security/* section is by default.
fn scope_delegated(params: Value) -> Result[string, string] {
    let site = param_str(params, "site", "")
    let path = param_str(params, "path", "")
    let store = param_str(params, "store", "apphost")
    if store == "apphost" {
        let base = " -PSPath 'MACHINE/WEBROOT/APPHOST'"
        if site == "" { return Ok(base) }
        return Ok(base + " -Location " + ps_q(site + path))
    }
    if store == "web_config" {
        if site == "" { return Err("store = :web_config needs a 'site'") }
        // The IIS provider documents backslashes throughout an IIS:\ path, so
        // the virtual path's forward slashes are converted and its leading and
        // trailing separators dropped: "/api/v2" under site "web" becomes
        // IIS:\Sites\web\api\v2, and "/" becomes IIS:\Sites\web.
        let rel = path.replace("/", "\\")
        if rel.starts_with("\\") { rel = rel.slice(1, rel.len()) }
        if rel.ends_with("\\") { rel = rel.slice(0, rel.len() - 1) }
        let full = if rel == "" { "IIS:\\Sites\\" + site } else { "IIS:\\Sites\\" + site + "\\" + rel }
        return Ok(" -PSPath " + ps_q(full))
    }
    Err("invalid 'store' value '" + store + "' (expected :apphost or :web_config)")
}

// Sections under system.applicationHost are never delegated: the site or
// pool is named in the filter's XPath instead of in a -Location.
fn scope_apphost(params: Value) -> Result[string, string] {
    Ok(" -PSPath 'MACHINE/WEBROOT/APPHOST'")
}

// The URL Rewrite section only exists once the separate module is installed,
// and a raw "filter is not a known section" from PowerShell tells nobody what
// to do about it. The rewrite resources call this before mutating anything.
fn require_rewrite() -> Result[unit, string] {
    let out = shell::powershell(
        "if (Test-Path (Join-Path $env:windir 'system32\\inetsrv\\rewrite.dll')) {{ 'YES' }} else {{ 'NO' }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    if out.stdout.trim() == "YES" { return Ok(()) }
    Err("the URL Rewrite module is not installed; add a windows_iis.rewrite_module step first")
}

// An XPath predicate value. IIS's own escaping stops at the apostrophe, so
// so does this: a site or path holding one is rejected rather than silently
// matching the wrong element.
fn xp(s: string) -> Result[string, string] {
    if s.contains("'") { return Err("'" + s + "' contains an apostrophe, which IIS configuration XPath cannot express") }
    Ok(s)
}

// ---------------------------------------------------------------------------
// An inbound URL Rewrite rule.
//
// A rule is not one element but four — the rule, its match, its conditions
// and its action — so it is written whole rather than attribute by
// attribute: the rule with this name is removed and rebuilt. That keeps the
// resource honest about what it owns (everything under the rule) and makes
// the ordering explicit, since a rebuilt rule lands at the end of the rule
// set and rules are evaluated in order.
//
// Conditions are "input|pattern" strings with an optional third field of
// comma-separated flags, because a list of records is not expressible as a
// param type: "{HTTPS}|^OFF$" or "{REQUEST_FILENAME}||isFile,negate".
// ---------------------------------------------------------------------------

fn rules_filter() -> string { "system.webServer/rewrite/rules" }

fn rule_name(params: Value) -> Result[string, string] {
    let n = param_str(params, "name", "")
    if n == "" { return Err("missing 'name' parameter") }
    Ok(n)
}

fn rule_filter(params: Value) -> Result[string, string] {
    Ok(rules_filter() + "/rule[@name='" + xp(rule_name(params)?)? + "']")
}

fn pattern_syntax(v: string) -> Result[string, string] {
    if v == "" { return Ok("") }
    if v == "ecma_script" { return Ok("ECMAScript") }
    if v == "wildcard" { return Ok("Wildcard") }
    if v == "exact_match" { return Ok("ExactMatch") }
    Err("invalid 'pattern_syntax' value '" + v + "'")
}

fn logical_grouping(v: string) -> Result[string, string] {
    if v == "" { return Ok("") }
    if v == "match_all" { return Ok("MatchAll") }
    if v == "match_any" { return Ok("MatchAny") }
    Err("invalid logical grouping '" + v + "'")
}

fn action_type(v: string) -> Result[string, string] {
    if v == "" { return Ok("") }
    if v == "rewrite" { return Ok("Rewrite") }
    if v == "redirect" { return Ok("Redirect") }
    if v == "custom_response" { return Ok("CustomResponse") }
    if v == "abort_request" { return Ok("AbortRequest") }
    if v == "none" { return Ok("None") }
    Err("invalid 'action_type' value '" + v + "'")
}

fn redirect_type(v: string) -> Result[string, string] {
    if v == "" { return Ok("") }
    if v == "permanent" { return Ok("Permanent") }
    if v == "found" { return Ok("Found") }
    if v == "see_other" { return Ok("SeeOther") }
    if v == "temporary" { return Ok("Temporary") }
    Err("invalid 'redirect_type' value '" + v + "'")
}

// One condition, parsed from "input|pattern" or "input|pattern|flags", where
// flags is any of negate, isFile, isDirectory and pattern.
// Returns [input, pattern, matchType, negate].
fn parse_condition(spec: string) -> Result[List[string], string] {
    let parts = spec.split("|")
    if parts.len() < 2 {
        return Err("condition '" + spec + "' must be written \"input|pattern\"")
    }
    let match_type = "Pattern"
    let negate = "false"
    if parts.len() > 2 {
        for f in parts.get(2).unwrap_or("").split(",") {
            let flag = f.trim().to_lower()
            if flag == "" { continue }
            if flag == "negate" { negate = "true" }
            else if flag == "isfile" { match_type = "IsFile" }
            else if flag == "isdirectory" { match_type = "IsDirectory" }
            else if flag == "pattern" { match_type = "Pattern" }
            else { return Err("unknown condition flag '" + flag + "' in '" + spec + "'") }
        }
    }
    Ok([parts.get(0).unwrap_or(""), parts.get(1).unwrap_or(""), match_type, negate])
}

// The canonical text the probe also produces, so the two can be compared.
fn conditions_text(params: Value) -> Result[string, string] {
    let out: List[string] = []
    for spec in param_list(params, "conditions") {
        let c = parse_condition(spec)?
        out.push(c.get(0).unwrap_or("") + "|" + c.get(1).unwrap_or("") + "|" +
            c.get(2).unwrap_or("").to_lower() + "|" + c.get(3).unwrap_or("").to_lower())
    }
    Ok(out.join(";;"))
}

// 'ABSENT', or the rule flattened to the shape conditions_text and the param
// accessors compare against. A missing rewrite section reads as ABSENT so a
// check on a machine without the module reports drift rather than erroring.
fn probe(params: Value) -> Result[string, string] {
    ps_out(
        "$r = @(); try {{ $r = @(Get-WebConfiguration" + scope_delegated(params)? + " -Filter " +
        ps_q(rules_filter() + "/rule") + " | Where-Object {{ [string]$_.name -eq " +
        ps_q(rule_name(params)?) + " }}) }} catch {{ }}; " +
        "if ($r.Count -eq 0) {{ 'ABSENT' }} else {{ $x = $r[0]; " +
        "$conds = @($x.conditions.Collection | ForEach-Object {{ " +
        "([string]$_.input + '|' + [string]$_.pattern + '|' + " +
        "([string]$_.matchType).ToLower() + '|' + ([string]$_.negate).ToLower()) }}); " +
        "[pscustomobject]@{{ " +
        "enabled = CwV($x.enabled); stop_processing = CwV($x.stopProcessing); " +
        "pattern_syntax = CwV($x.patternSyntax); match_url = CwV($x.match.url); " +
        "ignore_case = CwV($x.match.ignoreCase); negate = CwV($x.match.negate); " +
        "conditions_logical_grouping = CwV($x.conditions.logicalGrouping); " +
        "conditions_track_all_captures = CwV($x.conditions.trackAllCaptures); " +
        "action_type = CwV($x.action.type); action_url = CwV($x.action.url); " +
        "append_query_string = CwV($x.action.appendQueryString); " +
        "log_rewritten_url = CwV($x.action.logRewrittenUrl); " +
        "redirect_type = CwV($x.action.redirectType); " +
        "status_code = CwV($x.action.statusCode); sub_status_code = CwV($x.action.subStatusCode); " +
        "status_reason = CwV($x.action.statusReason); " +
        "status_description = CwV($x.action.statusDescription); " +
        "conditions = ($conds -join ';;') }} | ConvertTo-Json -Compress }}")
}

fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
}

// [key in the probe, desired text] for everything the step named. `element`
// says which of the four elements the attribute belongs to and `attribute`
// its IIS name; both are only needed by apply.
fn wanted(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    if has(params, "enabled") {
        out.push(["enabled", if param_bool(params, "enabled", true) { "true" } else { "false" },
            "", "enabled", "bool"])
    }
    if has(params, "stop_processing") {
        out.push(["stop_processing",
            if param_bool(params, "stop_processing", false) { "true" } else { "false" },
            "", "stopProcessing", "bool"])
    }
    let syntax = pattern_syntax(param_str(params, "pattern_syntax", ""))?
    if syntax != "" { out.push(["pattern_syntax", syntax, "", "patternSyntax", "str"]) }
    let url = param_str(params, "match_url", "")
    if url != "" { out.push(["match_url", url, "/match", "url", "str"]) }
    if has(params, "ignore_case") {
        out.push(["ignore_case", if param_bool(params, "ignore_case", true) { "true" } else { "false" },
            "/match", "ignoreCase", "bool"])
    }
    if has(params, "negate") {
        out.push(["negate", if param_bool(params, "negate", false) { "true" } else { "false" },
            "/match", "negate", "bool"])
    }
    let grouping = logical_grouping(param_str(params, "conditions_logical_grouping", ""))?
    if grouping != "" {
        out.push(["conditions_logical_grouping", grouping, "/conditions", "logicalGrouping", "str"])
    }
    if has(params, "conditions_track_all_captures") {
        out.push(["conditions_track_all_captures",
            if param_bool(params, "conditions_track_all_captures", false) { "true" } else { "false" },
            "/conditions", "trackAllCaptures", "bool"])
    }
    let atype = action_type(param_str(params, "action_type", ""))?
    if atype != "" { out.push(["action_type", atype, "/action", "type", "str"]) }
    let aurl = param_str(params, "action_url", "")
    if aurl != "" { out.push(["action_url", aurl, "/action", "url", "str"]) }
    if has(params, "append_query_string") {
        out.push(["append_query_string",
            if param_bool(params, "append_query_string", true) { "true" } else { "false" },
            "/action", "appendQueryString", "bool"])
    }
    if has(params, "log_rewritten_url") {
        out.push(["log_rewritten_url",
            if param_bool(params, "log_rewritten_url", true) { "true" } else { "false" },
            "/action", "logRewrittenUrl", "bool"])
    }
    let rtype = redirect_type(param_str(params, "redirect_type", ""))?
    if rtype != "" { out.push(["redirect_type", rtype, "/action", "redirectType", "str"]) }
    if has(params, "status_code") {
        out.push(["status_code", itoa(param_int(params, "status_code", 0)),
            "/action", "statusCode", "int"])
    }
    if has(params, "sub_status_code") {
        out.push(["sub_status_code", itoa(param_int(params, "sub_status_code", 0)),
            "/action", "subStatusCode", "int"])
    }
    let reason = param_str(params, "status_reason", "")
    if reason != "" { out.push(["status_reason", reason, "/action", "statusReason", "str"]) }
    let desc = param_str(params, "status_description", "")
    if desc != "" { out.push(["status_description", desc, "/action", "statusDescription", "str"]) }
    Ok(out)
}

// Whether the live rule already matches everything this step asks for. apply
// uses it to avoid rebuilding — and so reordering — a converged rule.
fn converged(params: Value) -> Result[bool, string] {
    let st = probe(params)?
    if st == "ABSENT" { return Ok(false) }
    let r = json::parse(st)?
    for row in wanted(params)? {
        if !same(get_str(r, row.get(0).unwrap_or("")), row.get(1).unwrap_or("")) {
            return Ok(false)
        }
    }
    Ok(get_str(r, "conditions") == conditions_text(params)?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let r = json::parse(st)?
    for row in wanted(params)? {
        if !same(get_str(r, row.get(0).unwrap_or("")), row.get(1).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    if get_str(r, "conditions") != conditions_text(params)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn ps_value(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    if kind == "int" { return want }
    ps_q(want)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_rewrite()?
    let name = rule_name(params)?
    let scope = scope_delegated(params)?
    let st = probe(params)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing rewrite rule " + name)
        ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + ps_q(rules_filter()) +
            " -Name '.' -AtElement @{{name=" + ps_q(name) + "}}")?
        return Ok(ApplyResult::Success)
    }
    if param_str(params, "match_url", "") == "" {
        return Err("'match_url' is required when ensure is :present")
    }
    // Nothing differs: return without touching anything. These resources
    // rebuild the element rather than patching it, and rebuilding moves it to
    // the end of its collection — rewrite rules are evaluated in order, so a converged
    // re-run must not touch them at all.
    if converged(params)? { return Ok(ApplyResult::Success) }
    let script = ""
    if st != "ABSENT" {
        script = script + "Remove-WebConfigurationProperty" + scope + " -Filter " +
            ps_q(rules_filter()) + " -Name '.' -AtElement @{{name=" + ps_q(name) + "}}; "
    }
    script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + ps_q(rules_filter()) +
        " -Name '.' -Value @{{name=" + ps_q(name) + "}}; "
    let rule = rule_filter(params)?
    for row in wanted(params)? {
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " +
            ps_q(rule + row.get(2).unwrap_or("")) + " -Name " + ps_q(row.get(3).unwrap_or("")) +
            " -Value " + ps_value(row.get(4).unwrap_or(""), row.get(1).unwrap_or("")) + "; "
    }
    for spec in param_list(params, "conditions") {
        let c = parse_condition(spec)?
        script = script + "Add-WebConfigurationProperty" + scope + " -Filter " +
            ps_q(rule + "/conditions") + " -Name '.' -Value @{{input=" +
            ps_q(c.get(0).unwrap_or("")) + "; pattern=" + ps_q(c.get(1).unwrap_or("")) +
            "; matchType=" + ps_q(c.get(2).unwrap_or("")) + "; negate=" +
            (if c.get(3).unwrap_or("") == "true" { "$true" } else { "$false" }) + "}}; "
    }
    log::info("writing rewrite rule " + name)
    ps_run(script)?
    Ok(ApplyResult::Success)
}
