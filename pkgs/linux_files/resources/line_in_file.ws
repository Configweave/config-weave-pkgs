use value
use fs
use path
use log
use common

// One literal line in a text file: present exactly once, or absent.
//
// Matching is exact, byte for byte, against whole lines split on "\n"; a
// line ending "\r" (a CRLF file) does not match. Newline policy: a file
// that already holds the right lines is never rewritten, so a missing final
// newline alone is not drift. Every write ends the file with "\n", except a
// file whose last line was removed, which is left empty.

fn want_line(params: Value) -> Result[string, string] {
    let line = common::param_str(params, "line", "")
    if line == "" { return Err("missing 'line' parameter (an empty line is not allowed)") }
    if line.contains("\n") || line.contains("\r") {
        return Err("'line' must be a single line without CR or LF characters")
    }
    Ok(line)
}

fn count_matches(lines: List[string], line: string) -> int {
    let n = 0
    for l in lines { if l == line { n = n + 1 } }
    n
}

// The new line list: present keeps the first match and drops the others,
// or appends the line when there is none; absent drops every match. Other
// lines keep their order.
fn edited(lines: List[string], line: string, present: bool) -> List[string] {
    let out: List[string] = []
    let seen = false
    for l in lines {
        if l == line {
            if present && !seen { out.push(l) }
            seen = true
        } else {
            out.push(l)
        }
    }
    if present && !seen { out.push(line) }
    out
}

// The path must be a file, a symlink to one, a dangling symlink or nothing.
fn require_not_dir(p: string) -> Result[unit, string] {
    if fs::is_dir(p) { return Err("path is a directory: " + p) }
    Ok(())
}

struct Want {
    path: string,
    line: string,
    present: bool,
    create: bool,
}

fn want(params: Value) -> Result[Want, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let line = want_line(params)?
    let present = common::want_present(params)?
    require_not_dir(p)?
    Ok(Want { path: p, line: line, present: present, create: common::param_bool(params, "create", true) })
}

fn check(params: Value) -> Result[CheckResult, string] {
    let w = want(params)?
    if !fs::is_file(w.path) {
        // Absent never creates a file. A missing file with create = false
        // is reported by apply, so a check-only run does not fail on a file
        // an earlier step would create.
        if w.present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let n = count_matches(common::split_lines(common::read_text(w.path, "line_in_file")?), w.line)
    let ok = if w.present { n == 1 } else { n == 0 }
    if ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    // No mode/owner/group params: install keeps the old file's owner,
    // group and mode (of the target when path is a symlink), and writes
    // through a symlink at path.
    if !fs::is_file(w.path) {
        if !w.present { return Ok(ApplyResult::Success) }
        if !w.create { return Err("'" + w.path + "' does not exist and create is false") }
        log::info("creating " + w.path)
        fs::mkdir(path::parent(w.path))?
        let tmp = common::tmp_sibling(w.path)
        fs::write(tmp, w.line + "\n")?
        common::install_edited(tmp, w.path, params)?
        return Ok(ApplyResult::Success)
    }
    let lines = common::split_lines(common::read_text(w.path, "line_in_file")?)
    let n = count_matches(lines, w.line)
    if (w.present && n == 1) || (!w.present && n == 0) { return Ok(ApplyResult::Success) }
    log::info("editing " + w.path)
    let tmp = common::tmp_sibling(w.path)
    fs::write(tmp, common::join_lines(edited(lines, w.line, w.present)))?
    common::install_edited(tmp, w.path, params)?
    Ok(ApplyResult::Success)
}
