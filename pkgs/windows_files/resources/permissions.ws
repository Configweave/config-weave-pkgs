use value
use fs
use path
use log
use common
use access
use acl

// Reads and writes the descriptor through the host acl module; see
// lib/access.ws for how the rules are compared and merged.

fn mode_exact(params: Value) -> Result[bool, string] {
    let m = common::param_str(params, "acl_mode", "additive")
    if m == "additive" { return Ok(false) }
    if m == "exact" { return Ok(true) }
    Err("invalid 'acl_mode' value '" + m + "' (expected :additive or :exact)")
}

fn copy_inherited(params: Value) -> Result[bool, string] {
    let m = common::param_str(params, "inherited_rules", "copy")
    if m == "copy" { return Ok(true) }
    if m == "remove" { return Ok(false) }
    Err("invalid 'inherited_rules' value '" + m + "' (expected :copy or :remove)")
}

// acl refuses a reparse point, while the rules always applied to what a
// link points at, so a final link (or a chain of them) is followed here.
fn resolve(p: string) -> Result[string, string] {
    let cur = p
    for i in 0..32 {
        let t = fs::read_link(cur)
        if t.is_err() { return Ok(cur) }
        let target = t.unwrap_or("")
        let abs = target.len() >= 2 && (target.slice(1, 2) == ":" || target.starts_with("\\\\"))
        cur = if abs { target } else { path::join(path::parent(cur), target) }
    }
    Err("too many levels of links at '" + p + "'")
}

// Rules on a directory apply to the folder, its subfolders and files; a
// file's rules carry no inheritance.
fn flags(p: string) -> List[string] { if fs::is_dir(p) { ["container", "object"] } else { [] } }

struct Want {
    owner: string,
    rules: List[Rule],
    exact: bool,
    protect: bool,
    copy: bool,
}

// Validation that needs no account lookups runs first, so a bad param
// fails even while the path does not exist yet.
fn validate(params: Value) -> Result[unit, string] {
    mode_exact(params)?
    copy_inherited(params)?
    for kind in ["acl", "deny"] {
        for spec in common::param_strs(params, kind) {
            let pp = access::spec_parts(spec)?
            access::parse_rights("file", pp.get(0).unwrap_or(""), pp.get(1).unwrap_or(""))?
        }
    }
    Ok(())
}

fn want(params: Value, target: string) -> Result[Want, string] {
    let owner = common::param_str(params, "owner", "")
    Ok(Want {
        owner: if owner != "" { access::sid_of(owner)? } else { "" },
        rules: access::wanted("file", common::param_strs(params, "acl"), common::param_strs(params, "deny"), flags(target))?,
        exact: mode_exact(params)?,
        protect: !common::param_bool(params, "inheritance", true),
        copy: copy_inherited(params)?,
    })
}

fn problems(cur: Current, w: Want) -> List[string] {
    let out = access::drift(cur, w.rules, w.exact, true)
    if w.owner != "" && cur.owner != w.owner { out.push("owner is " + cur.owner + ", wanted " + w.owner) }
    if cur.protected != w.protect { out.push("inheritance is " + (if cur.protected { "off" } else { "on" })) }
    out
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    validate(params)?
    // A missing path is NotConfigured (not an error) so a sibling step can
    // create it before this resource's apply runs; apply still errors when
    // the path never appears.
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    let target = resolve(p)?
    let w = want(params, target)?
    let cur = access::current("file", target, Value::Null, fs::is_dir(target))?
    let drift = problems(cur, w)
    if !drift.is_empty() {
        for d in drift { log::info(p + ": " + d) }
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    validate(params)?
    if !fs::exists(p) { return Err("path does not exist: " + p) }
    let target = resolve(p)?
    let w = want(params, target)?
    let cur = access::current("file", target, Value::Null, fs::is_dir(target))?
    if problems(cur, w).is_empty() { return Ok(ApplyResult::Success) }
    // Cutting inheritance with inherited_rules = :copy keeps the inherited
    // rules as explicit ones, so nobody loses access they had; acl::set
    // drops them otherwise. They take part in the comparison like any other
    // explicit rule.
    if w.protect && !cur.protected && w.copy {
        for r in cur.inherited {
            cur.explicit.push(Rule { sid: r.sid, kind: r.kind, mask: r.mask, inherit: r.inherit, inherited: false })
        }
    }
    let rules = access::merged(cur, w.rules, w.exact, true)?
    let owner = if w.owner != "" && cur.owner != w.owner { w.owner } else { "" }
    log::info("setting the ACL of " + p)
    acl::set(target, access::spec(rules, owner, Some(w.protect)), Value::Null)?
    Ok(ApplyResult::Success)
}
