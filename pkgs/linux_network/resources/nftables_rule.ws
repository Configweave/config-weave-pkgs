use value
use common
use shell

fn ident(params: Value) -> Result[string, string] {
    let family = common::nft_family(params)?
    let table = common::param_str(params, "table", "")
    let chain = common::param_str(params, "chain", "")
    common::nft_name("table", table)?
    common::nft_name("chain", chain)?
    Ok(common::nft_ref(family, [table, chain]))
}

// The rule goes into an `nft -f` script, where a line break or ';' would
// start a second command.
fn valid_rule(params: Value) -> Result[string, string] {
    let rule = common::param_str(params, "rule", "").trim()
    if rule == "" { return Err("missing 'rule' parameter") }
    common::one_line("rule", rule)?
    if rule.contains(";") { return Err("'rule' must be a single rule; ';' would start another nft command") }
    Ok(rule)
}

fn is_number(s: string) -> bool {
    if s == "" { return false }
    for c in s.chars() { if c < '0' || c > '9' { return false } }
    true
}

// A rule in the form compared: whitespace collapsed, the "# handle N" that
// `nft -a` appends removed, and the state nft adds to stateful statements
// dropped ("counter packets 3 bytes 180" -> "counter", "quota 10 mbytes
// used 2 kbytes" -> "quota 10 mbytes"), so a rule that has seen traffic
// still matches the param that created it.
fn normalise(rule: string) -> string {
    let body = rule
    if let Some(i) = body.find(" # handle ") { body = body.slice(0, i) }
    let toks = []
    for t in body.replace("\t", " ").split(" ") { if t != "" { toks.push(t) } }
    let out = []
    let quota = false
    let i = 0
    while i < toks.len() {
        let t = toks.get(i).unwrap_or("")
        if t == "quota" { quota = true }
        if t == "packets" && out.len() > 0 && out.get(out.len() - 1).unwrap_or("") == "counter" && i + 3 < toks.len() && toks.get(i + 2).unwrap_or("") == "bytes" && is_number(toks.get(i + 1).unwrap_or("")) {
            i = i + 4
            continue
        }
        if t == "used" && quota && i + 2 < toks.len() && is_number(toks.get(i + 1).unwrap_or("")) {
            i = i + 3
            continue
        }
        out.push(t)
        i = i + 1
    }
    out.join(" ")
}

// Handles of the chain's rules that match `rule`; None when the chain (or
// its table) does not exist, which is the normal case during a check run
// before the step creating the chain has applied.
fn handles(id: string, rule: string) -> Result[Option[List[string]], string] {
    let listed = common::nft_list("-a", "chain " + id)?
    if listed.is_none() { return Ok(None) }
    let want = normalise(rule)
    let out = []
    for line in listed.unwrap_or("").split("\n") {
        let t = line.trim()
        if let Some(i) = t.find(" # handle ") {
            if normalise(t) == want { out.push(t.slice(i + " # handle ".len(), t.len()).trim()) }
        }
    }
    Ok(Some(out))
}

fn present(id: string, rule: string) -> Result[bool, string] {
    if let Some(hs) = handles(id, rule)? { return Ok(!hs.is_empty()) }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    common::require_nft()?
    let id = ident(params)?
    let rule = valid_rule(params)?
    if present(id, rule)? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_nft()?
    let id = ident(params)?
    let rule = valid_rule(params)?
    if !common::want_present(params)? {
        // every copy goes, so a rule added twice by hand is removed too
        let script = ""
        if let Some(hs) = handles(id, rule)? {
            for h in hs { script = script + "delete rule " + id + " handle " + h + "\n" }
        }
        if script != "" { let out = common::nft_script("deleting rule from " + id, script, "")? }
        return Ok(ApplyResult::Success)
    }
    if present(id, rule)? { return Ok(ApplyResult::Success) }
    // --echo prints the rule back as nft stores it. When that differs from
    // the param (nft rewrote "tcp dport ssh" as "tcp dport 22", say), the
    // next check could never find it and every run would add another copy,
    // so the rule is taken out again and the error names the stored form.
    let out = common::nft_script("adding rule to " + id, "add rule " + id + " " + rule, "--echo --handle")?
    if present(id, rule)? { return Ok(ApplyResult::Success) }
    for line in out.stdout.split("\n") {
        let t = line.trim()
        let prefix = "add rule " + id + " "
        if !t.starts_with(prefix) { continue }
        if let Some(i) = t.find(" # handle ") {
            let h = t.slice(i + " # handle ".len(), t.len()).trim()
            let undo = common::nft_script("removing the rule just added to " + id, "delete rule " + id + " handle " + h, "")?
            return Err("nft stores this rule as '" + normalise(t.slice(prefix.len(), t.len())) + "'; write 'rule' in that form so it can be found again")
        }
    }
    Err("added the rule to " + id + " but cannot find it again; write 'rule' exactly as nft list chain prints it (nft echoed: " + out.stdout.trim() + ")")
}
