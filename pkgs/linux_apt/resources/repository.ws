use value
use fs
use path
use common

fn dir() -> string { "/etc/apt/sources.list.d/" }

// One-line style is <name>.list; deb822 stanzas are <name>.sources.
fn ext(format: string) -> Result[string, string] {
    if format == "list" { return Ok(".list") }
    if format == "deb822" { return Ok(".sources") }
    Err("invalid 'format' value '" + format + "' (expected :list or :deb822)")
}

fn validate(params: Value) -> Result[unit, string] {
    common::file_name("name", common::param_str(params, "name", ""))?
    ext(common::param_str(params, "format", "list"))?
    Ok(())
}

// The file this name and format own, and the other format's file for the
// same name, which is drift: apt would read both.
fn paths(params: Value) -> Result[List[string], string] {
    let name = common::param_str(params, "name", "")
    let fmt = common::param_str(params, "format", "list")
    let other = if fmt == "list" { "deb822" } else { "list" }
    Ok([dir() + name + ext(fmt)?, dir() + name + ext(other)?])
}

// A file that cannot be read as text holds something other than content.
fn holds(p: string, content: string) -> bool {
    if !fs::is_file(p) { return false }
    if let Ok(text) = fs::read(p) { text == content } else { false }
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let ps = paths(params)?
    if !common::want_present(params)? {
        if fs::is_file(ps[0]) || fs::is_file(ps[1]) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    if holds(ps[0], content) && !fs::is_file(ps[1]) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let ps = paths(params)?
    if fs::is_file(ps[1]) { fs::delete(ps[1])? }
    if !common::want_present(params)? {
        if fs::is_file(ps[0]) { fs::delete(ps[0])? }
        return Ok(ApplyResult::Success)
    }
    let content = common::param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    fs::mkdir(path::parent(ps[0]))?
    fs::write(ps[0], content)?
    Ok(ApplyResult::Success)
}
