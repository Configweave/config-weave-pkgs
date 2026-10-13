use value
use fs
use common

fn validate(params: Value, present: bool) -> Result[unit, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if name == "options" { return Err("'options' is pacman's own section, not a repository") }
    if name.starts_with(".") || name.starts_with("-") || !name.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == '+' || c == '@') {
        return Err("invalid 'name' '" + name + "': use letters, digits, '_', '-', '.', '+' and '@', not starting with '.' or '-'")
    }
    common::one_line("siglevel", common::param_str(params, "siglevel", ""))?
    let servers = common::param_list(params, "servers")
    for s in servers {
        common::one_line("servers", s)?
        if s.trim() == "" { return Err("'servers' must not contain an empty URL") }
    }
    if present && servers.len() == 0 { return Err("'servers' needs at least one URL when present") }
    Ok(())
}

// The section body pacman should read, in order.
fn desired(params: Value) -> List[string] {
    let out = []
    let sig = common::param_str(params, "siglevel", "").trim()
    if sig != "" { out.push("SigLevel = " + sig) }
    for s in common::param_list(params, "servers") { out.push("Server = " + s.trim()) }
    out
}

// [header index, index of the section's last setting] for section name, or
// [] when there is none. Comments after the last setting are left out:
// they usually belong to what follows (a commented-out [testing] block).
fn find_section(ls: List[string], name: string) -> List[int] {
    for i in 0..ls.len() {
        if common::header(ls[i]) == name {
            let last = i
            let j = i + 1
            while j < ls.len() && common::header(ls[j]) == "" {
                if common::setting(ls[j]) != "" { last = j }
                j = j + 1
            }
            return [i, last]
        }
    }
    []
}

fn current(ls: List[string], sec: List[int]) -> List[string] {
    let out = []
    for i in (sec[0] + 1)..(sec[1] + 1) {
        let s = common::setting(ls[i])
        if s != "" { out.push(s) }
    }
    out
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let ls = common::conf_lines(common::read_conf()?)
    let sec = find_section(ls, common::param_str(params, "name", ""))
    let ok = if present { sec.len() == 2 && current(ls, sec) == desired(params) } else { sec.len() == 0 }
    if ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

// A change to pacman.conf makes the next cache_updated sync, so the new
// repository's database is fetched.
fn apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let name = common::param_str(params, "name", "")
    let ls = common::conf_lines(common::read_conf()?)
    let sec = find_section(ls, name)
    let out = []
    if present && sec.len() == 0 {
        // appended, so it is searched after every repository already there
        for l in ls { out.push(l) }
        if ls.len() > 0 && ls[ls.len() - 1].trim() != "" { out.push("") }
        out.push("[" + name + "]")
        for d in desired(params) { out.push(d) }
    } else if present {
        // rewritten in place, keeping its position in the search order
        for i in 0..ls.len() {
            if i > sec[0] && i <= sec[1] { continue }
            out.push(ls[i])
            if i == sec[0] { for d in desired(params) { out.push(d) } }
        }
    } else {
        if sec.len() == 0 { return Ok(ApplyResult::Success) }
        // the blank line that separated it goes with it
        let from = if sec[0] > 0 && ls[sec[0] - 1].trim() == "" { sec[0] - 1 } else { sec[0] }
        for i in 0..ls.len() {
            if i >= from && i <= sec[1] { continue }
            out.push(ls[i])
        }
    }
    fs::write(common::pacman_conf(), common::conf_text(out))?
    Ok(ApplyResult::Success)
}
