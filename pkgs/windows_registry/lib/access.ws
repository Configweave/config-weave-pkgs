// Owner and explicit-rule handling on top of the host acl module. The
// comparison is done here rather than with acl::diff, because "additive"
// means "at least these rights", which diff's exact set comparison cannot
// express; acl::set then writes the result. Masks are bit sets and wscript
// has no bitwise operators, so they are combined bit by bit.
//
// windows_files and windows_registry each carry an identical copy of this
// file (packages never share a lib); `target` is "file" or "registry".
use value
use fs
use path
use acl
use common

// ---------------------------------------------------------------------
// Bits
// ---------------------------------------------------------------------

fn bits_or(a: int, b: int) -> int {
    let out = 0
    let bit = 1
    let x = a
    let y = b
    while x > 0 || y > 0 {
        if x % 2 == 1 || y % 2 == 1 { out = out + bit }
        x = x / 2
        y = y / 2
        bit = bit * 2
    }
    out
}

fn bits_and(a: int, b: int) -> int {
    let out = 0
    let bit = 1
    let x = a
    let y = b
    while x > 0 && y > 0 {
        if x % 2 == 1 && y % 2 == 1 { out = out + bit }
        x = x / 2
        y = y / 2
        bit = bit * 2
    }
    out
}

fn covers(have: int, want: int) -> bool { bits_and(have, want) == want }

// ---------------------------------------------------------------------
// Rights
// ---------------------------------------------------------------------

fn synchronize() -> int { 1048576 }

fn full_control(target: string) -> int { if target == "registry" { 983103 } else { 2032127 } }

// The .NET FileSystemRights or RegistryRights names (aliases included),
// lower-cased without spaces or underscores, so "ReadAndExecute",
// "readandexecute" and "read_and_execute" are one name, as .NET's
// case-insensitive enum parse allowed.
fn rights_table(target: string) -> Map[string, int] {
    if target == "registry" {
        return #{
            "fullcontrol": 983103, "readkey": 131097, "executekey": 131097, "writekey": 131078,
            "queryvalues": 1, "setvalue": 2, "createsubkey": 4, "enumeratesubkeys": 8, "notify": 16,
            "createlink": 32, "delete": 65536, "readpermissions": 131072, "changepermissions": 262144,
            "takeownership": 524288
        }
    }
    #{
        "fullcontrol": 2032127, "modify": 197055, "readandexecute": 131241, "read": 131209, "write": 278,
        "readdata": 1, "listdirectory": 1, "writedata": 2, "createfiles": 2, "appenddata": 4,
        "createdirectories": 4, "readextendedattributes": 8, "writeextendedattributes": 16,
        "executefile": 32, "traverse": 32, "deletesubdirectoriesandfiles": 64, "readattributes": 128,
        "writeattributes": 256, "delete": 65536, "readpermissions": 131072, "changepermissions": 262144,
        "takeownership": 524288, "synchronize": 1048576
    }
}

// "Read, Write", "ReadAndExecute" or a number → a mask.
fn parse_rights(target: string, ident: string, rights: string) -> Result[int, string] {
    let table = rights_table(target)
    let hint = if target == "registry" {
        "invalid registry rights '" + rights + "' for " + ident + ": use RegistryRights names such as ReadKey, WriteKey or FullControl"
    } else {
        "invalid file system rights '" + rights + "' for " + ident + ": use FileSystemRights names such as ReadAndExecute, Modify, Read, Write or FullControl"
    }
    let mask = 0
    for raw in rights.split(",") {
        let name = raw.trim().to_lower().replace("_", "").replace(" ", "")
        if name == "" { return Err(hint) }
        if name.chars().all(|c| c >= '0' && c <= '9') {
            mask = bits_or(mask, name.parse_int().unwrap_or(0))
        } else if let Some(m) = table.get(name) {
            mask = bits_or(mask, m)
        } else {
            return Err(hint)
        }
    }
    Ok(mask)
}

// The mask .NET stores for a rule, which is what the rules on existing
// paths carry and what these resources always compared against: a file
// Allow rule gains Synchronize, a file Deny rule loses it unless it is
// FullControl. Registry rules are stored as given.
fn stored_mask(target: string, mask: int, kind: string) -> int {
    if target == "registry" { return mask }
    if kind == "allow" { return bits_or(mask, synchronize()) }
    if mask == full_control(target) { return mask }
    mask - bits_and(mask, synchronize())
}

// One "identity:rights" spec → [identity, rights]. The rights may be a
// comma-separated list ("Read, Write"), so the spec is split at its last
// colon.
fn spec_parts(spec: string) -> Result[List[string], string] {
    let parts = spec.split(":")
    if parts.len() >= 2 {
        let last = parts.get(parts.len() - 1).unwrap_or("")
        let rights = last.trim()
        let ident = spec.slice(0, spec.len() - last.len() - 1).trim()
        if ident != "" && rights != "" && !spec.contains("\n") && !spec.contains("\r") { return Ok([ident, rights]) }
    }
    Err("invalid rule '" + spec + "' (expected \"identity:rights\", e.g. \"BUILTIN\\Users:ReadAndExecute\")")
}

// ---------------------------------------------------------------------
// Principals
// ---------------------------------------------------------------------

// The SID an account name or SID string stands for, in canonical form.
// acl::lookup resolves either with LookupAccountNameW (config-weave v0.10.0
// or later); a SID string nobody holds still comes back as its SID.
fn sid_of(name: string) -> Result[string, string] {
    let got = acl::lookup(name)
    if let Err(e) = got { return Err("cannot resolve account '" + name + "' to a SID: " + e) }
    let sid = common::get_str(got?, "sid")
    if sid == "" { return Err("cannot resolve account '" + name + "' to a SID") }
    Ok(sid)
}

// ---------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------

struct Rule {
    sid: string,
    kind: string,
    mask: int,
    inherit: List[string],
    inherited: bool,
}

fn flags_of(e: Value) -> List[string] {
    let out: List[string] = []
    for f in common::get_list(e, "inherit") { out.push(f.as_string().unwrap_or("")) }
    out.sort()
    out
}

fn rule_of(e: Value) -> Rule {
    Rule {
        sid: common::get_str(e, "sid"),
        kind: common::get_str(e, "kind"),
        mask: common::get_int(e, "mask"),
        inherit: flags_of(e),
        inherited: common::get_bool(e, "inherited"),
    }
}

fn rule_value(r: Rule) -> Value {
    let flags: List[Value] = []
    for f in r.inherit { flags.push(Value::String(f)) }
    Value::Map(#{
        "principal": Value::String(r.sid),
        "kind": Value::String(r.kind),
        "mask": Value::Int(r.mask),
        "inherit": Value::List(flags)
    })
}

// The wanted rules: "identity:rights" specs resolved to SIDs, several specs
// for one identity and kind merged into one mask, each with `flags`.
fn wanted(target: string, allow: List[string], deny: List[string], flags: List[string]) -> Result[List[Rule], string] {
    let out: List[Rule] = []
    add_wanted(target, out, allow, "allow", flags)?
    add_wanted(target, out, deny, "deny", flags)?
    Ok(out)
}

fn add_wanted(target: string, out: List[Rule], specs: List[string], kind: string, flags: List[string]) -> Result[unit, string] {
    for spec in specs {
        let pp = spec_parts(spec)?
        let ident = pp.get(0).unwrap_or("")
        let mask = stored_mask(target, parse_rights(target, ident, pp.get(1).unwrap_or(""))?, kind)
        let sid = sid_of(ident)?
        let merged = false
        for i in 0..out.len() {
            let w = out[i]
            if w.sid == sid && w.kind == kind {
                out.set(i, Rule { sid: sid, kind: kind, mask: bits_or(w.mask, mask), inherit: flags, inherited: false })
                merged = true
            }
        }
        if !merged { out.push(Rule { sid: sid, kind: kind, mask: mask, inherit: flags, inherited: false }) }
    }
    Ok(())
}

// What the path's descriptor holds, in the shape the evaluation needs. A
// NULL DACL (everyone has full access) reads as one explicit Everyone
// FullControl rule that reaches everything below, exactly as .NET's
// security classes present it, so additive mode keeps that access and
// exact mode removes it.
struct Current {
    owner: string,
    protected: bool,
    explicit: List[Rule],
    inherited: List[Rule],
    other: int,
}

fn current(target: string, p: string, opts: Value, container: bool) -> Result[Current, string] {
    let r = acl::read(p, opts)?
    let owner = ""
    if let Some(o) = r.get("owner") { owner = common::get_str(o, "sid") }
    let explicit: List[Rule] = []
    let inherited: List[Rule] = []
    let other = 0
    if common::get_bool(r, "null_dacl") {
        let flags: List[string] = if container { if target == "registry" { ["container"] } else { ["container", "object"] } } else { [] }
        explicit.push(Rule { sid: "S-1-1-0", kind: "allow", mask: full_control(target), inherit: flags, inherited: false })
    }
    for e in common::get_list(r, "entries") {
        let k = common::get_str(e, "kind")
        if k != "allow" && k != "deny" {
            other = other + 1
            continue
        }
        let rule = rule_of(e)
        if rule.inherited { inherited.push(rule) } else { explicit.push(rule) }
    }
    Ok(Current { owner: owner, protected: common::get_bool(r, "protected"), explicit: explicit, inherited: inherited, other: other })
}

// Whether an explicit rule's inheritance counts towards a want with
// `flags`. `exact_flags` (files) needs the very same flags; otherwise
// (registry keys) the rule must reach the key and every subkey: container
// inheritance, not inherit-only and not stopped at the first level.
fn flags_ok(r: Rule, flags: List[string], exact_flags: bool) -> bool {
    if exact_flags { return r.inherit.join(",") == flags.join(",") }
    r.inherit.contains("container") && !r.inherit.contains("inherit_only") && !r.inherit.contains("no_propagate")
}

// The drift between the explicit rules and the wants, one line each. A want
// is met when its identity's matching explicit rules together hold at least
// its mask; in exact mode they must hold exactly it with no rule of other
// inheritance, and an unlisted explicit rule is drift too.
fn drift(cur: Current, wants: List[Rule], exact: bool, exact_flags: bool) -> List[string] {
    let out: List[string] = []
    for w in wants {
        let have = 0
        let odd = false
        for r in cur.explicit {
            if r.sid != w.sid || r.kind != w.kind { continue }
            if flags_ok(r, w.inherit, exact_flags) { have = bits_or(have, r.mask) } else { odd = true }
        }
        let ok = covers(have, w.mask)
        if exact && (odd || have != w.mask) { ok = false }
        if !ok { out.push(w.kind + " " + w.sid + " wants mask " + str(w.mask) + ", explicit rules give " + str(have)) }
    }
    if exact {
        for r in cur.explicit {
            let listed = false
            for w in wants { if w.sid == r.sid && w.kind == r.kind { listed = true } }
            if !listed { out.push("unlisted explicit " + r.kind + " rule for " + r.sid) }
        }
        if cur.other > 0 { out.push(str(cur.other) + " explicit object or callback entries") }
    }
    out
}

// The explicit rules to write. Exact mode writes the wants alone. Additive
// mode keeps every explicit rule and adds each unmet want, merged into the
// rule of the same identity, kind and inheritance where there is one (as
// .NET's AddAccessRule merged it).
fn merged(cur: Current, wants: List[Rule], exact: bool, exact_flags: bool) -> Result[List[Rule], string] {
    if exact { return Ok(wants.clone()) }
    if cur.other > 0 {
        return Err("the ACL holds " + str(cur.other) + " object or callback entries, which cannot be rewritten; use exact mode to replace them")
    }
    let out = cur.explicit.clone()
    for w in wants {
        let have = 0
        for r in cur.explicit {
            if r.sid == w.sid && r.kind == w.kind && flags_ok(r, w.inherit, exact_flags) { have = bits_or(have, r.mask) }
        }
        if covers(have, w.mask) { continue }
        let done = false
        for i in 0..out.len() {
            let r = out[i]
            if !done && r.sid == w.sid && r.kind == w.kind && r.inherit.join(",") == w.inherit.join(",") {
                out.set(i, Rule { sid: r.sid, kind: r.kind, mask: bits_or(r.mask, w.mask), inherit: r.inherit, inherited: false })
                done = true
            }
        }
        if !done { out.push(w) }
    }
    Ok(out)
}

fn spec(rules: List[Rule], owner: string, protected: Option[bool]) -> Value {
    let entries: List[Value] = []
    for r in rules { entries.push(rule_value(r)) }
    let m: Map[string, Value] = #{ "entries": Value::List(entries) }
    if owner != "" { m.insert("owner", Value::String(owner)) }
    if let Some(b) = protected { m.insert("protected", Value::Bool(b)) }
    Value::Map(m)
}
