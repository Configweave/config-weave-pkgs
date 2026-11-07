use value
use fs
use path
use log
use shell
use common

// One managed block of lines in a text file, between the marker lines
// "# BEGIN <label>" and "# END <label>": present with the wanted content,
// or absent with its markers.
//
// Markers are whole lines compared byte for byte; a marker line ending
// "\r" (a CRLF file) or with extra spaces is ordinary text. The file must
// hold either no marker line for the label or exactly one BEGIN line
// followed later by one END line. Anything else (an unmatched, reversed,
// nested or duplicate marker) is an error, never a guess.
//
// Newline policy: one trailing "\n" of 'block' is dropped, so "a\n" and
// "a" are the same block. A file that already holds the wanted state is
// never rewritten, so a missing final newline alone is not drift. Every
// write ends the file with "\n", except a file whose only content was the
// removed block, which is left empty.

struct Want {
    path: string,
    begin: string,
    end: string,
    body: List[string],
    present: bool,
    create: bool,
}

// The file's lines without the terminator after the last one: "" gives no
// lines, "a\nb\n" and "a\nb" both give ["a", "b"].
fn split_lines(text: string) -> List[string] {
    let out: List[string] = []
    if text == "" { return out }
    let parts = text.split("\n")
    let n = parts.len()
    if text.ends_with("\n") { n = n - 1 }
    let i = 0
    while i < n {
        out.push(parts.get(i).unwrap_or(""))
        i = i + 1
    }
    out
}

fn join_lines(lines: List[string]) -> string {
    if lines.is_empty() { return "" }
    lines.join("\n") + "\n"
}

fn want_label(params: Value) -> Result[string, string] {
    let label = common::param_str(params, "marker_label", "config-weave")
    if label == "" { return Err("'marker_label' must not be empty") }
    if label.contains("\n") || label.contains("\r") {
        return Err("'marker_label' must be a single line without CR or LF characters")
    }
    Ok(label)
}

// The block's lines. Only checked for :present; :absent needs no content.
fn want_body(params: Value, begin: string, end: string) -> Result[List[string], string] {
    // "\n" is one dropped trailing newline, so it is empty too; split_lines
    // alone would read it as one empty line.
    let text = common::param_str(params, "block", "")
    let body = split_lines(text)
    if text == "\n" || body.is_empty() { return Err("missing 'block' parameter (an empty block is not allowed with :present)") }
    for l in body {
        if l == begin || l == end {
            return Err("'block' must not contain its own marker line '" + l + "'")
        }
    }
    Ok(body)
}

// The path must be a file, a symlink to one, a dangling symlink or nothing.
fn require_not_dir(p: string) -> Result[unit, string] {
    if fs::is_dir(p) { return Err("path is a directory: " + p) }
    Ok(())
}

fn want(params: Value) -> Result[Want, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let label = want_label(params)?
    let begin = "# BEGIN " + label
    let end = "# END " + label
    let present = common::want_present(params)?
    let body: List[string] = []
    if present { body = want_body(params, begin, end)? }
    require_not_dir(p)?
    Ok(Want {
        path: p,
        begin: begin,
        end: end,
        body: body,
        present: present,
        create: common::param_bool(params, "create", true),
    })
}

// A file that cannot be read as UTF-8 text is an error, not drift: a
// rewrite would destroy content this resource does not understand.
fn read_text(p: string) -> Result[string, string] {
    if let Ok(text) = fs::read(p) { return Ok(text) }
    Err("cannot read '" + p + "' as UTF-8 text; block_in_file edits text files only")
}

// The owned block as [begin index, end index], or [-1, -1] when the file
// has no marker line for the label. Malformed markers are an error.
fn find_block(lines: List[string], w: Want) -> Result[List[int], string] {
    let b = -1
    let e = -1
    let i = 0
    for l in lines {
        if l == w.begin {
            if b >= 0 { return Err("'" + w.path + "' has more than one '" + w.begin + "' line (nested or duplicate block)") }
            b = i
        } else if l == w.end {
            if e >= 0 { return Err("'" + w.path + "' has more than one '" + w.end + "' line (nested or duplicate block)") }
            if b < 0 { return Err("'" + w.path + "' has '" + w.end + "' without a '" + w.begin + "' line before it") }
            e = i
        }
        i = i + 1
    }
    if b >= 0 && e < 0 { return Err("'" + w.path + "' has '" + w.begin + "' without a matching '" + w.end + "' line") }
    Ok([b, e])
}

fn wanted_block(w: Want) -> List[string] {
    let out: List[string] = [w.begin]
    for l in w.body { out.push(l) }
    out.push(w.end)
    out
}

// The new line list, or None when the file already holds the wanted state.
// Lines outside the owned block keep their content and order.
fn edited(lines: List[string], w: Want) -> Result[Option[List[string]], string] {
    let span = find_block(lines, w)?
    let b = span.get(0).unwrap_or(-1)
    let e = span.get(1).unwrap_or(-1)
    if b < 0 {
        if !w.present { return Ok(None) }
        let out: List[string] = []
        for l in lines { out.push(l) }
        for l in wanted_block(w) { out.push(l) }
        return Ok(Some(out))
    }
    if w.present && e - b - 1 == w.body.len() {
        let same = true
        let i = 0
        for l in w.body {
            if lines.get(b + 1 + i).unwrap_or("") != l { same = false }
            i = i + 1
        }
        if same { return Ok(None) }
    }
    let out: List[string] = []
    let i = 0
    for l in lines {
        if i == b && w.present {
            for x in wanted_block(w) { out.push(x) }
        }
        if i < b || i > e { out.push(l) }
        i = i + 1
    }
    Ok(Some(out))
}

// Put the edited temp file in place. A symlink at path is written through
// by common::install_tmp, and that copy gives the target the temp file's
// mode. So for a symlink to an existing file, read the target's owner,
// group and mode first (stat -L, numeric ids) and set them back after the
// write. chown and chmod follow the link, so the link itself is kept.
fn install(tmp: string, p: string, params: Value) -> Result[unit, string] {
    let none = common::attrs(params)?
    if fs::read_link(p).is_err() || !fs::is_file(p) { return common::install_tmp(tmp, p, none) }
    let out = shell::bash("stat -L -c '%a %u %g' -- " + common::q(p), Value::Null)?
    if !out.success {
        fs::delete(tmp).unwrap_or(())
        return Err(common::cmd_err("stat " + p, out))
    }
    let f = out.stdout.trim().split(" ")
    let mode = f.get(0).unwrap_or("")
    let ids = f.get(1).unwrap_or("") + ":" + f.get(2).unwrap_or("")
    common::install_tmp(tmp, p, none)?
    // chown first: it clears setuid/setgid bits, which the chmod puts back.
    common::run("chown " + p, "chown -- " + common::q(ids) + " " + common::q(p))?
    common::run("chmod " + p, "chmod -- " + common::q(mode) + " " + common::q(p))
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
    let next = edited(split_lines(read_text(w.path)?), w)?
    if next.is_none() { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
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
        fs::write(tmp, join_lines(wanted_block(w)))?
        install(tmp, w.path, params)?
        return Ok(ApplyResult::Success)
    }
    let next = edited(split_lines(read_text(w.path)?), w)?
    if let Some(lines) = next {
        log::info("editing " + w.path)
        let tmp = common::tmp_sibling(w.path)
        fs::write(tmp, join_lines(lines))?
        install(tmp, w.path, params)?
    }
    Ok(ApplyResult::Success)
}
