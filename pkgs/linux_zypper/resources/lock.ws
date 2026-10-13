use value
use common

// zypper locks prints a table; the columns differ between versions, so
// they are found by header. Only package locks count: a pattern or patch
// lock of the same name is not a hold on the package.
fn is_locked(name: string) -> Result[bool, string] {
    let out = common::output("zypper locks", common::zypper_cmd("locks"))?
    let name_col = -1
    let type_col = -1
    for l in out.stdout.split("\n") {
        if !l.contains("|") { continue }
        let cells = []
        for c in l.split("|") { cells.push(c.trim()) }
        if name_col < 0 {
            let i = 0
            for c in cells {
                if c == "Name" { name_col = i }
                if c == "Type" { type_col = i }
                i = i + 1
            }
            continue
        }
        if cells.len() <= name_col || cells[name_col] != name { continue }
        if type_col < 0 || cells.len() <= type_col || cells[type_col] == "package" { return Ok(true) }
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    if is_locked(name)? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    let verb = if common::want_present(params)? { "addlock" } else { "removelock" }
    common::zypper("zypper " + verb + " " + name, verb + " " + common::q(name), false)?
    Ok(ApplyResult::Success)
}
