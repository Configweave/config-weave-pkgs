use value
use fs
use log
use shell
use regex
use common

// Replace every match of a regex in an existing text file.
//
// The new content is regex::replace(pattern, old, replacement): every byte
// outside a match is kept, the final-newline state included, and a file
// with no match is already configured. A substitution has no inverse, so
// there is no ensure param.
//
// Fixed-point rule: the substitution must not change its own output. When
// replace(output) != output (a -> aa, or a pattern that matches its own
// replacement in a growing way), the step is an error, in check and in
// apply, before anything is written. A stable result is what makes the
// re-check after apply, and every later run, report already configured.

struct Want {
    path: string,
    pattern: string,
    replacement: string,
}

fn want(params: Value) -> Result[Want, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let pattern = common::param_str(params, "pattern", "")
    if pattern == "" { return Err("missing 'pattern' parameter (an empty pattern is not allowed)") }
    // An invalid pattern faults here, before any file is read; the engine
    // reports the fault as the step's error.
    let probe = regex::is_match(pattern, "")
    let replacement = common::param_str(params, "replacement", "")
    if fs::is_dir(p) { return Err("path is a directory: " + p) }
    Ok(Want { path: p, pattern: pattern, replacement: replacement })
}

// A file that cannot be read as UTF-8 text is an error, not drift: a
// rewrite would destroy content this resource does not understand.
fn read_text(p: string) -> Result[string, string] {
    if let Ok(text) = fs::read(p) { return Ok(text) }
    Err("cannot read '" + p + "' as UTF-8 text; file_substitution edits text files only")
}

fn missing(p: string) -> string {
    "'" + p + "' does not exist; file_substitution edits existing files only"
}

// The substituted content, or None when the file already holds it. An
// error when the result is not a fixed point of the substitution.
fn substituted(w: Want, text: string) -> Result[Option[string], string] {
    let out = regex::replace(w.pattern, text, w.replacement)
    if out == text { return Ok(None) }
    if regex::replace(w.pattern, out, w.replacement) != out {
        return Err("the substitution does not converge on '" + w.path + "': applying it to its own output changes the text again, so every run would rewrite the file. Change pattern or replacement so that the replaced text no longer matches")
    }
    Ok(Some(out))
}

// Put the edited temp file in place. A symlink at path is written through
// by common::install_tmp, and that copy gives the target the temp file's
// mode. So for a symlink to an existing file, read the target's owner,
// group and mode first (stat -L, numeric ids) and set them back after the
// write. chown and chmod follow the link, so the link itself is kept.
// Same helper as in line_in_file.ws and block_in_file.ws.
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
    // A missing file is reported by apply, so a check-only run does not
    // fail on a file that an earlier step would create.
    if !fs::is_file(w.path) { return Ok(CheckResult::NotConfigured) }
    if let Some(out) = substituted(w, read_text(w.path)?)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    if !fs::is_file(w.path) { return Err(missing(w.path)) }
    if let Some(out) = substituted(w, read_text(w.path)?)? {
        // No mode/owner/group params: install keeps the old file's owner,
        // group and mode (of the target when path is a symlink), and
        // writes through a symlink at path.
        log::info("substituting in " + w.path)
        let tmp = common::tmp_sibling(w.path)
        fs::write(tmp, out)?
        install(tmp, w.path, params)?
    }
    Ok(ApplyResult::Success)
}
