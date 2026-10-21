// Profile paths and the managed-block contract shared by profile_snippet,
// psreadline_option, psreadline_key_handler, default_parameter_values and
// preference_variable.
use value
use fs
use path
use sys
use common
use user_tree

// None when the PowerShell that has to be asked is not installed.
fn profile_dir(params: Value, all_users: bool) -> Result[Option[string], string] {
    let edition = common::param_str(params, "edition", "auto")
    if all_users {
        if let Some(home) = common::query(edition, "Write-Output $PSHOME")? { return Ok(Some(home)) }
        return Ok(None)
    }
    let home = common::param_str(params, "home", "")
    if home != "" {
        if sys::family() == "windows" {
            let folder = if common::resolved_edition(edition) == "windows_powershell" { "WindowsPowerShell" } else { "PowerShell" }
            return Ok(Some(path::join(path::join(home, "Documents"), folder)))
        }
        return Ok(Some(path::join(path::join(home, ".config"), "powershell")))
    }
    // No home: the profile of the account config-weave runs as, which for a
    // service agent is usually SYSTEM or root, not an interactive user.
    if let Some(dir) = common::query(edition, "Write-Output (Split-Path -Parent $PROFILE.CurrentUserCurrentHost)")? { return Ok(Some(dir)) }
    Ok(None)
}

fn profile_path(params: Value) -> Result[Option[string], string] {
    let explicit = common::param_str(params, "path", "")
    if explicit != "" { return Ok(Some(explicit)) }
    let scope = common::param_str(params, "scope", "current_user_current_host")
    let valid = ["all_users_all_hosts", "all_users_current_host", "current_user_all_hosts", "current_user_current_host"]
    if !valid.contains(scope) { return Err("invalid 'scope' value '" + scope + "'") }
    let host = common::param_str(params, "host", "Microsoft.PowerShell")
    common::path_segment("host", host)?
    if let Some(dir) = profile_dir(params, scope.starts_with("all_users"))? {
        if scope.ends_with("all_hosts") { return Ok(Some(path::join(dir, "profile.ps1"))) }
        return Ok(Some(path::join(dir, host + "_profile.ps1")))
    }
    Ok(None)
}

// The user root a profile path lives under (see user_tree): None for an
// all-users profile or an explicit `path`, Some(home) for a current-user one.
fn user_root(params: Value) -> Option[string] {
    if common::param_str(params, "path", "") != "" { return None }
    if common::param_str(params, "scope", "current_user_current_host").starts_with("all_users") { return None }
    Some(user_tree::root_of(common::param_str(params, "home", "")))
}

// profile_path, with a link in the user's tree refused. Every resource
// resolves its profile through this, so check and apply both error on one.
fn guarded_profile_path(params: Value) -> Result[Option[string], string] {
    let resolved = profile_path(params)?
    if let Some(file) = resolved { user_tree::guard(user_root(params), file)? }
    Ok(resolved)
}

fn require_profile_path(params: Value) -> Result[string, string] {
    if let Some(file) = guarded_profile_path(params)? { return Ok(file) }
    Err("cannot resolve the profile path: " + common::not_installed(common::param_str(params, "edition", "auto")))
}

// Windows PowerShell 5.1 reads a BOM-less script as the ANSI code page, so a
// profile it loads gets a UTF-8 BOM. PowerShell 7 reads either.
fn wants_bom(params: Value) -> bool {
    common::resolved_edition(common::param_str(params, "edition", "auto")) == "windows_powershell"
}

fn has_bom(text: string) -> bool { text.starts_with("\u{FEFF}") }

fn strip_bom(text: string) -> string {
    if has_bom(text) { return text.slice(1, text.len()) }
    text
}

fn norm_eol(text: string) -> string { text.replace("\r\n", "\n") }

// None when the file does not exist. An unreadable file (not UTF-8) is an
// error the caller decides about. A link in a user's tree is an error too:
// resolve the path with guarded_profile_path first so check reports it
// rather than reading it as drift.
fn read_text(params: Value, file: string) -> Result[Option[string], string] {
    user_tree::read(user_root(params), file)
}

fn write_text(params: Value, file: string, text: string, bom: bool) -> Result[unit, string] {
    let body = strip_bom(text)
    user_tree::write(user_root(params), file, if bom { "\u{FEFF}" + body } else { body })
}

fn begin_marker(name: string) -> string { "# BEGIN config-weave: " + name }
fn end_marker(name: string) -> string { "# END config-weave: " + name }

fn strip_cr(line: string) -> string {
    if line.ends_with("\r") { return line.slice(0, line.len() - 1) }
    line
}

// extract_block / merge_block are deliberately pure string functions: the
// whole convergence contract of the block-writing resources lives in them.
// Both take text with any BOM already stripped.

// The body currently between this block's markers (line endings normalised
// to LF), or None when the block is not in the text. A BEGIN with no END is
// an error: guessing where the block stops would delete the rest of the
// profile.
fn extract_block(text: string, name: string) -> Result[Option[string], string] {
    let begin = begin_marker(name)
    let end = end_marker(name)
    let body: List[string] = []
    let inside = false
    let found = false
    for raw in text.split("\n") {
        let line = strip_cr(raw)
        if !inside && line.trim() == begin {
            inside = true
            found = true
            continue
        }
        if inside {
            if line.trim() == end { inside = false } else { body.push(line) }
        }
    }
    if inside { return Err("the profile has '" + begin + "' with no matching '" + end + "' line — fix the profile by hand; config-weave will not guess where the block ends") }
    if !found { return Ok(None) }
    Ok(Some(body.join("\n")))
}

// Replaces the block in place when it is already there, appends it otherwise,
// and drops it entirely when `body` is None — leaving every other line of the
// profile untouched. A file written with CRLF line endings keeps them.
fn merge_block(text: string, name: string, body: Option[string]) -> Result[string, string] {
    // Validates the markers before anything is rewritten.
    extract_block(text, name)?
    let crlf = text.contains("\r\n")
    let begin = begin_marker(name)
    let end = end_marker(name)
    let rendered = ""
    if let Some(b) = body { rendered = begin + "\n" + norm_eol(b) + "\n" + end }
    let kept: List[string] = []
    let inside = false
    let seen = false
    for raw in text.split("\n") {
        let line = strip_cr(raw)
        if !inside && line.trim() == begin {
            inside = true
            seen = true
            if rendered != "" { kept.push(rendered) }
            continue
        }
        if inside {
            if line.trim() == end { inside = false }
            continue
        }
        kept.push(line)
    }
    let head = kept.join("\n").trim_end()
    let merged = ""
    if seen || rendered == "" {
        merged = if head == "" { "" } else { head + "\n" }
    } else if head == "" {
        merged = rendered + "\n"
    } else {
        merged = head + "\n\n" + rendered + "\n"
    }
    if crlf { return Ok(merged.replace("\n", "\r\n")) }
    Ok(merged)
}

// Shared check for a managed block. `body` is None for ensure = :absent.
fn check_block(params: Value, name: string, body: Option[string]) -> Result[CheckResult, string] {
    common::single_line("block name", name)?
    let present = body.is_some()
    let resolved = guarded_profile_path(params)?
    if resolved.is_none() {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let file = resolved.unwrap()
    let read = read_text(params, file)
    // A profile that exists but is not UTF-8 cannot be compared; apply will
    // say why it cannot rewrite it.
    if read.is_err() { return Ok(CheckResult::NotConfigured) }
    let raw = read.unwrap()
    if raw.is_none() {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let text = raw.unwrap()
    let current = extract_block(strip_bom(text), name)?
    if !present {
        if current.is_none() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if wants_bom(params) && !has_bom(text) { return Ok(CheckResult::NotConfigured) }
    if let Some(existing) = current {
        if existing == norm_eol(body.unwrap()) { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply_block(params: Value, name: string, body: Option[string]) -> Result[ApplyResult, string] {
    common::single_line("block name", name)?
    let file = require_profile_path(params)?
    let existing = ""
    let bom = wants_bom(params)
    let read = read_text(params, file)
    if let Err(e) = read { return Err("cannot read the profile '" + file + "' as UTF-8 (" + e + ") — re-save it as UTF-8 so config-weave can edit it without corrupting it") }
    if let Some(text) = read.unwrap() {
        existing = text
        if has_bom(existing) { bom = true }
    }
    let merged = merge_block(strip_bom(existing), name, body)?
    write_text(params, file, merged, bom && merged != "")?
    Ok(ApplyResult::Success)
}

// The body of one block, or None when the profile, the file or the block is
// missing or the file cannot be read.
fn current_block(params: Value, name: string) -> Result[Option[string], string] {
    let resolved = guarded_profile_path(params)?
    if resolved.is_none() { return Ok(None) }
    let read = read_text(params, resolved.unwrap())
    if read.is_err() { return Ok(None) }
    if let Some(text) = read.unwrap() { return extract_block(strip_bom(text), name) }
    Ok(None)
}
