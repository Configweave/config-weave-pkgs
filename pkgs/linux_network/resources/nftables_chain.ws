use value
use common
use json

struct Spec {
    // "" for a regular chain
    kind: string,
    hook: string,
    priority: int,
    // "" leaves the policy unmanaged
    policy: string,
}

fn ident(params: Value) -> Result[string, string] {
    let family = common::nft_family(params)?
    let table = common::param_str(params, "table", "")
    let name = common::param_str(params, "name", "")
    common::nft_name("table", table)?
    common::nft_name("name", name)?
    Ok(common::nft_ref(family, [table, name]))
}

fn wanted(params: Value) -> Result[Spec, string] {
    let kind = common::param_str(params, "type", "")
    let hook = common::param_str(params, "hook", "")
    let policy = common::param_str(params, "policy", "")
    if kind != "" && kind != "filter" && kind != "nat" && kind != "route" {
        return Err("invalid 'type' value '" + kind + "' (expected :filter, :nat or :route)")
    }
    if hook != "" && hook != "prerouting" && hook != "input" && hook != "forward" && hook != "output" && hook != "postrouting" {
        return Err("invalid 'hook' value '" + hook + "' (expected :prerouting, :input, :forward, :output or :postrouting)")
    }
    if policy != "" && policy != "accept" && policy != "drop" {
        return Err("invalid 'policy' value '" + policy + "' (expected :accept or :drop)")
    }
    if (kind == "") != (hook == "") { return Err("'type' and 'hook' must be set together for a base chain") }
    if kind == "" && policy != "" { return Err("'policy' applies only to a base chain; set 'type' and 'hook' too") }
    Ok(Spec { kind: kind, hook: hook, priority: common::param_int(params, "priority", 0), policy: policy })
}

fn field_str(m: Value, k: string) -> string {
    if let Some(v) = m.get(k) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn field_int(m: Value, k: string) -> int {
    if let Some(v) = m.get(k) { if let Some(i) = v.as_int() { return i } }
    0
}

// The chain as nft reports it (`nft -j list chain`), or None when it (or
// its table) does not exist. A regular chain has no type or hook.
fn current(id: string) -> Result[Option[Spec], string] {
    let listed = common::nft_list("-j", "chain " + id)?
    if listed.is_none() { return Ok(None) }
    let doc = json::parse(listed.unwrap_or(""))?
    if let Some(v) = doc.get("nftables") {
        if let Some(items) = v.as_list() {
            for item in items {
                if let Some(c) = item.get("chain") {
                    return Ok(Some(Spec {
                        kind: field_str(c, "type"),
                        hook: field_str(c, "hook"),
                        priority: field_int(c, "prio"),
                        policy: field_str(c, "policy"),
                    }))
                }
            }
        }
    }
    Err("nft -j list chain " + id + " returned no chain")
}

// type, hook and priority are fixed once a chain exists: changing them
// means deleting the chain and creating it again.
fn same_shape(have: Spec, want: Spec) -> bool {
    have.kind == want.kind && have.hook == want.hook && (want.kind == "" || have.priority == want.priority)
}

fn converged(have: Spec, want: Spec) -> bool {
    same_shape(have, want) && (want.policy == "" || have.policy == want.policy)
}

fn spec_text(want: Spec) -> string {
    if want.kind == "" { return "" }
    let policy = if want.policy != "" { " policy " + want.policy + ";" } else { "" }
    " {{ type " + want.kind + " hook " + want.hook + " priority " + str(want.priority) + ";" + policy + " }}"
}

fn check(params: Value) -> Result[CheckResult, string] {
    common::require_nft()?
    let id = ident(params)?
    let want = wanted(params)?
    let have = current(id)?
    if !common::want_present(params)? {
        if have.is_some() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if let Some(h) = have {
        if converged(h, want) { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_nft()?
    let id = ident(params)?
    let want = wanted(params)?
    let have = current(id)?
    // A chain must be empty to be deleted, so flush it first, in the same
    // transaction. A chain another chain still jumps to cannot be deleted;
    // nft's error says so.
    let drop = "flush chain " + id + "\ndelete chain " + id + "\n"
    if !common::want_present(params)? {
        if have.is_none() { return Ok(ApplyResult::Success) }
        let out = common::nft_script("deleting chain " + id, drop, "")?
        return Ok(ApplyResult::Success)
    }
    let create = "add chain " + id + spec_text(want)
    let script = create
    if let Some(h) = have {
        // Same shape: `add chain` with the full spec updates the policy in
        // place and keeps the rules. A new type, hook or priority means
        // recreating the chain, which drops its rules; the nftables_rule
        // steps that require this one add them back.
        if !same_shape(h, want) { script = drop + create }
    }
    let out = common::nft_script("creating chain " + id, script, "")?
    Ok(ApplyResult::Success)
}
