use value
use json
use log
use common

// ---------------------------------------------------------------------------
// Section machinery: the read-diff-write every section script runs over the
// attributes it names. A section script declares a SectionSpec and hands it
// to check() and apply() here.
// ---------------------------------------------------------------------------

// filter: the section path, e.g. system.webServer/defaultDocument.
// scope:  the -PSPath/-Location arguments, from common::scope_delegated or
//         common::scope_apphost.
// attrs:  [param, IIS attribute, kind] rows.
// syms:   [param, symbol value, IIS token] rows.
// extra:  [param, IIS attribute, kind, text] rows wanted whatever the params
//         say — how a script writes a value the params cannot spell, such as
//         the empty userName that selects the pool identity.
//
// Kinds: bool, int, str, sym, flags (compared as a set), vlist (an ordered
// collection of value= entries), dur (a TimeSpan), dur_sec and dur_ms (an
// integer from a duration param), and secret (a str that is masked in the log
// and passed to PowerShell through the environment).
struct SectionSpec {
    filter: string,
    scope: string,
    attrs: List[List[string]],
    syms: List[List[string]],
    extra: List[List[string]],
}

// The IIS spelling of a symbol value. Symbols are validated against the
// declared set by config-weave, so all that is left here is spelling: WCL
// symbols cannot contain a dot, a hyphen or a capital, so the tokens are
// written out rather than derived.
fn iis_symbol(spec: SectionSpec, name: string, v: string) -> string {
    for row in spec.syms {
        if row.get(0).unwrap_or("") == name && row.get(1).unwrap_or("") == v {
            return row.get(2).unwrap_or("")
        }
    }
    v
}

// The text IIS stores for a param the step supplied, or None when the step
// left it alone. An explicit empty string counts as "leave it alone" too:
// every optional string param here carries default = "", so it is always
// present in the map and absence cannot be the signal.
fn desired(params: Value, spec: SectionSpec, name: string, kind: string) -> Option[string] {
    if !common::has(params, name) { return None }
    if kind == "bool" {
        if common::param_bool(params, name, false) { return Some("true") }
        return Some("false")
    }
    if kind == "int" { return Some(common::itoa(common::param_int(params, name, 0))) }
    if kind == "dur" { return Some(common::hms(common::param_int(params, name, 0))) }
    if kind == "dur_sec" { return Some(common::itoa(common::param_int(params, name, 0) / 1000000000)) }
    if kind == "dur_ms" { return Some(common::itoa(common::param_int(params, name, 0) / 1000000)) }
    if kind == "flags" || kind == "vlist" { return Some(common::param_list(params, name).join(",")) }
    let raw = common::param_str(params, name, "")
    if raw == "" { return None }
    if kind == "sym" { return Some(iis_symbol(spec, name, raw)) }
    Some(raw)
}

// The [param, attribute, kind, desired text] rows this step asks for.
fn wanted(params: Value, spec: SectionSpec) -> List[List[string]] {
    let out: List[List[string]] = []
    for a in spec.attrs {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        if let Some(text) = desired(params, spec, name, kind) {
            out.push([name, a.get(1).unwrap_or(""), kind, text])
        }
    }
    for e in spec.extra { out.push(e) }
    out
}

// One PowerShell round trip reads every attribute the step named — and only
// those: reading an attribute whose feature is not installed errors, and a
// step that never mentions it should not have to care.
fn probe(spec: SectionSpec, rows: List[List[string]]) -> Result[Value, string] {
    let filter = common::ps_q(spec.filter)
    // Reads go through the section element rather than
    // Get-WebConfigurationProperty: that cmdlet hands back the raw value of an
    // enum attribute — sslFlags reads as 0, not None — while the provider
    // renders the schema name when the attribute is reached as a property.
    // Every symbol param in this package compares against the name.
    let reads = ""
    for r in rows {
        let name = common::ps_q(r.get(0).unwrap_or(""))
        let attr = r.get(1).unwrap_or("")
        reads = reads + "$o[" + name + "]=''; try {{ "
        if r.get(2).unwrap_or("") == "vlist" {
            reads = reads + "$o[" + name + "]=((@($s." + attr +
                ".Collection | ForEach-Object {{ [string]$_.value }})) -join ',')"
        } else {
            reads = reads + "$o[" + name + "]=CwV($s." + attr + ")"
        }
        reads = reads + " }} catch {{ }}; "
    }
    // A -Location for a site that does not exist yet cannot be read at all, so
    // the whole section read is guarded: every attribute then reports empty,
    // which is drift, which is the truth on a first run.
    json::parse(common::ps_out(
        "$o=@{{}}; $s=$null; try {{ $s = Get-WebConfiguration" + spec.scope + " -Filter " + filter +
        " }} catch {{ }}; if ($null -ne $s) {{ " + reads + "}}; " +
        "[pscustomobject]$o | ConvertTo-Json -Compress")?)
}

// IIS reports a flags attribute in its own order and spacing, and a symbol
// one with the schema's capitalisation, so neither is compared as text.
fn same(kind: string, have: string, want: string) -> bool {
    if kind == "flags" { return common::same_flags(have, want) }
    if kind == "bool" || kind == "sym" {
        return have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
    }
    have == want
}

// IIS's schema rejects a string where it wants a number or a flag, so a value
// is emitted as the PowerShell literal its type needs.
fn ps_value(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    if kind == "int" || kind == "dur_sec" || kind == "dur_ms" { return want }
    common::ps_q(want)
}

fn check(params: Value, spec: SectionSpec) -> Result[CheckResult, string] {
    let rows = wanted(params, spec)
    if rows.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    let have = probe(spec, rows)?
    for r in rows {
        let kind = r.get(2).unwrap_or("")
        if !same(kind, common::get_str(have, r.get(0).unwrap_or("")), r.get(3).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

// Writes every attribute that differs. True when anything was written, so a
// script with follow-up work (a service restart) knows to run it.
//
// A "secret" attribute is a string that never reaches the script text or the
// log: its value travels in an environment variable the script reads.
fn apply(params: Value, spec: SectionSpec) -> Result[bool, string] {
    let rows = wanted(params, spec)
    if rows.is_empty() { return Ok(false) }
    let have = probe(spec, rows)?
    let filter = common::ps_q(spec.filter)
    let script = ""
    let env: Map[string, Value] = #{}
    for r in rows {
        let name = r.get(0).unwrap_or("")
        let attr = r.get(1).unwrap_or("")
        let kind = r.get(2).unwrap_or("")
        let want = r.get(3).unwrap_or("")
        if same(kind, common::get_str(have, name), want) { continue }
        let set = "Set-WebConfigurationProperty" + spec.scope + " -Filter " + filter + " -Name " + common::ps_q(attr)
        if kind == "secret" {
            log::info("setting " + attr + " = ********")
            let var = "CW_SECRET_" + common::itoa(env.len())
            env.insert(var, Value::String(want))
            script = script + set + " -Value $env:" + var + "; "
        } else if kind == "vlist" {
            log::info("setting " + attr + " = [" + want + "]")
            let parts: List[string] = []
            for v in want.split(",") { if v != "" { parts.push("@{{value=" + common::ps_q(v) + "}}") } }
            if parts.is_empty() {
                // An empty list. Set-WebConfigurationProperty -Value @()
                // throws a NullReferenceException; removing every entry
                // writes <clear/>, so nothing is inherited either.
                // Clear-WebConfiguration would revert to the inherited list.
                script = script + "Remove-WebConfigurationProperty" + spec.scope + " -Filter " +
                    common::ps_q(spec.filter + "/" + attr.replace(".", "/")) + " -Name '.'; "
            } else {
                // Set-WebConfigurationProperty on a collection name REPLACES
                // the collection, which is what an ordered list needs:
                // appending would leave the inherited entries in front.
                script = script + set + " -Value @(" + parts.join(",") + "); "
            }
        } else {
            log::info("setting " + attr + " = " + want)
            script = script + set + " -Value " + ps_value(kind, want) + "; "
        }
    }
    if script == "" { return Ok(false) }
    common::ps_run_env(script, Value::Map(env))?
    Ok(true)
}
