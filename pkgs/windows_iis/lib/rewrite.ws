use value
use common

// ---------------------------------------------------------------------------
// Helpers shared by the URL Rewrite rule, outbound rule and pre-condition
// scripts: symbol spellings and the "input|pattern|flags" condition strings.
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
    for spec in common::param_list(params, "conditions") {
        let c = parse_condition(spec)?
        out.push(c.get(0).unwrap_or("") + "|" + c.get(1).unwrap_or("") + "|" +
            c.get(2).unwrap_or("").to_lower() + "|" + c.get(3).unwrap_or("").to_lower())
    }
    Ok(out.join(";;"))
}
