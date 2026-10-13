use value
use fs
use common

// The IgnorePkg entries of a pacman.conf IgnorePkg line, or [] for any
// other line. Commented-out lines are not entries.
fn entries(line: string) -> List[string] {
    let s = common::setting(line)
    if !s.starts_with("IgnorePkg = ") { return [] }
    let out = []
    for t in s.slice(12, s.len()).replace("\t", " ").split(" ") { if t != "" { out.push(t) } }
    out
}

// Indexes of the IgnorePkg lines inside [options] sections (pacman.conf
// may have more than one; the Arch container image appends a second).
fn ignore_lines(ls: List[string]) -> List[int] {
    let out = []
    let section = ""
    for i in 0..ls.len() {
        let h = common::header(ls[i])
        if h != "" { section = h; continue }
        if section == "options" && entries(ls[i]).len() > 0 { out.push(i) }
    }
    out
}

fn held(ls: List[string], name: string) -> bool {
    for i in ignore_lines(ls) { if entries(ls[i]).contains(name) { return true } }
    false
}

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    Ok(name)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let ls = common::conf_lines(common::read_conf()?)
    if held(ls, name) == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let ls = common::conf_lines(common::read_conf()?)
    if held(ls, name) == present { return Ok(ApplyResult::Success) }
    let out = []
    if present {
        // onto the first IgnorePkg line, else a new one under [options]
        let existing = ignore_lines(ls)
        let first_options = -1
        for i in 0..ls.len() { if first_options < 0 && common::header(ls[i]) == "options" { first_options = i } }
        if existing.len() == 0 && first_options < 0 { return Err(common::pacman_conf() + " has no [options] section") }
        for i in 0..ls.len() {
            if existing.len() > 0 && i == existing[0] {
                out.push(ls[i].trim_end() + " " + name)
                continue
            }
            out.push(ls[i])
            if existing.len() == 0 && i == first_options { out.push("IgnorePkg = " + name) }
        }
    } else {
        let lines = ignore_lines(ls)
        for i in 0..ls.len() {
            if !lines.contains(i) { out.push(ls[i]); continue }
            let keep = entries(ls[i]).filter(|e| e != name)
            if keep.len() > 0 { out.push("IgnorePkg = " + keep.join(" ")) }
        }
    }
    fs::write(common::pacman_conf(), common::conf_text(out))?
    Ok(ApplyResult::Success)
}
