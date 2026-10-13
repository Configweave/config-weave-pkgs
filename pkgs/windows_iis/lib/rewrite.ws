use value
use json
use log
use common

// ---------------------------------------------------------------------------
// Helpers shared by the URL Rewrite rule, outbound rule and pre-condition
// scripts: symbol spellings, the "input|pattern|flags" condition strings, and
// the patch-in-place write every one of them does.
//
// A rule is an element with match, conditions and action children. Drift is
// patched where it stands — the attributes that differ are set, and a changed
// condition list is cleared and re-added — rather than removing and
// re-adding the rule, which moved it to the end of a collection that is
// evaluated in order. The whole write is one commit (Start-WebCommitDelay),
// so a request never sees a half-written rule.
// ---------------------------------------------------------------------------

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

// Whether a field is a flags field: one or more of negate, isFile,
// isDirectory and pattern, comma-separated.
fn is_flags(field: string) -> bool {
    let any = false
    for f in field.split(",") {
        let flag = f.trim().to_lower()
        if flag == "" { continue }
        if flag != "negate" && flag != "isfile" && flag != "isdirectory" && flag != "pattern" { return false }
        any = true
    }
    any
}

// One condition, parsed from "input|pattern" or "input|pattern|flags".
// Returns [input, pattern, matchType, negate].
//
// The input is everything before the first "|". The last field is flags only
// when there are at least three fields and every token in it is a known flag;
// otherwise the pattern runs to the end, so a regex alternation such as
// "{HTTP_HOST}|^(a|b)\.example$" keeps its "|".
fn parse_condition(spec: string) -> Result[List[string], string] {
    let parts = spec.split("|")
    if parts.len() < 2 {
        return Err("condition '" + spec + "' must be written \"input|pattern\"")
    }
    let last = parts.len() - 1
    let flags = ""
    let end = parts.len()
    if parts.len() >= 3 && is_flags(parts.get(last).unwrap_or("")) {
        flags = parts.get(last).unwrap_or("")
        end = last
    }
    let pattern: List[string] = []
    let i = 1
    while i < end { pattern.push(parts.get(i).unwrap_or("")); i = i + 1 }
    let match_type = "Pattern"
    let negate = "false"
    for f in flags.split(",") {
        let flag = f.trim().to_lower()
        if flag == "negate" { negate = "true" }
        else if flag == "isfile" { match_type = "IsFile" }
        else if flag == "isdirectory" { match_type = "IsDirectory" }
        else if flag == "pattern" { match_type = "Pattern" }
    }
    Ok([parts.get(0).unwrap_or(""), pattern.join("|"), match_type, negate])
}

fn conditions(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    for spec in common::param_list(params, "conditions") { out.push(parse_condition(spec)?) }
    Ok(out)
}

// PowerShell for a JSON-friendly array of the conditions in collection `expr`.
fn read_conditions(expr: string) -> string {
    "@(" + expr + " | ForEach-Object {{ [pscustomobject]@{{ input = [string]$_.input; " +
    "pattern = [string]$_.pattern; match_type = [string]$_.matchType; negate = CwV($_.negate) }} }})"
}

fn items(v: Option[Value]) -> List[Value] {
    let out: List[Value] = []
    if let Some(x) = v {
        if let Some(xs) = x.as_list() { for i in xs { out.push(i) } }
        else if let Some(m) = x.as_map() { out.push(Value::Map(m)) }
    }
    out
}

// Inputs and patterns compare exactly — a regex is case-sensitive text —
// and the match type and negate flag case-insensitively.
fn conditions_same(have: Value, want: List[List[string]]) -> bool {
    let h = items(have.get("conditions"))
    if h.len() != want.len() { return false }
    let i = 0
    while i < want.len() {
        let c = h.get(i).unwrap_or(Value::Null)
        let w = want.get(i).unwrap_or([])
        if common::get_str(c, "input") != w.get(0).unwrap_or("") { return false }
        if common::get_str(c, "pattern") != w.get(1).unwrap_or("") { return false }
        if common::get_str(c, "match_type").to_lower() != w.get(2).unwrap_or("").to_lower() { return false }
        if common::get_str(c, "negate").to_lower() != w.get(3).unwrap_or("").to_lower() { return false }
        i = i + 1
    }
    true
}

// PowerShell replacing the conditions under filter `coll`: removing every
// entry writes <clear/>, then each wanted condition is added in order.
fn conditions_script(scope: string, coll: string, want: List[List[string]], existing: bool) -> string {
    let script = ""
    if existing {
        script = script + "Remove-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(coll) + " -Name '.'; "
    }
    for c in want {
        script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(coll) +
            " -Name '.' -Value @{{input=" + common::ps_q(c.get(0).unwrap_or("")) +
            "; pattern=" + common::ps_q(c.get(1).unwrap_or("")) +
            "; matchType=" + common::ps_q(c.get(2).unwrap_or("")) + "; negate=" +
            (if c.get(3).unwrap_or("") == "true" { "$true" } else { "$false" }) + "}}; "
    }
    script
}

// Rows are [probe key, desired text, element suffix, IIS attribute, kind].
// Kinds: bool and sym (an enum) compare case-insensitively, flags as a set,
// int and str exactly — URLs, patterns and status text are case-sensitive.
fn same(kind: string, have: string, want: string) -> bool {
    if kind == "flags" { return common::same_flags(have, want) }
    if kind == "bool" || kind == "sym" { return have.to_lower() == want.to_lower() }
    have == want
}

fn literal(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    if kind == "int" { return want }
    common::ps_q(want)
}

fn bool_row(params: Value, key: string, fallback: bool, suffix: string, attr: string) -> Option[List[string]] {
    if !common::has(params, key) { return None }
    Some([key, if common::param_bool(params, key, fallback) { "true" } else { "false" }, suffix, attr, "bool"])
}

fn rows_same(rows: List[List[string]], have: Value) -> bool {
    for r in rows {
        if !same(r.get(4).unwrap_or(""), common::get_str(have, r.get(0).unwrap_or("")), r.get(1).unwrap_or("")) {
            return false
        }
    }
    true
}

// PowerShell setting every row that differs from `have` on element `elem`.
fn rows_script(scope: string, elem: string, rows: List[List[string]], have: Value) -> string {
    let script = ""
    for r in rows {
        let kind = r.get(4).unwrap_or("")
        if same(kind, common::get_str(have, r.get(0).unwrap_or("")), r.get(1).unwrap_or("")) { continue }
        script = script + common::set_prop(scope, common::ps_q(elem + r.get(2).unwrap_or("")),
            r.get(3).unwrap_or(""), literal(kind, r.get(1).unwrap_or("")),
            common::get_str(have, r.get(0).unwrap_or("")), r.get(1).unwrap_or(""))
    }
    script
}

// Runs the writes as one configuration commit.
fn commit(script: string) -> Result[unit, string] {
    common::ps_run("Start-WebCommitDelay; " + script + "Stop-WebCommitDelay -Commit $true")
}
