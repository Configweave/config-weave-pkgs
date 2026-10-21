use value
use sys
use common
use config_file

fn sep() -> string { if sys::family() == "windows" { ";" } else { ":" } }

fn current_entries(doc: Value) -> List[string] {
    let out: List[string] = []
    if let Some(v) = doc.get("PSModulePath") {
        if let Some(s) = v.as_string() {
            for part in s.split(sep()) {
                let trimmed = part.trim()
                if trimmed != "" { out.push(trimmed) }
            }
        }
    }
    out
}

// The PSModulePath setting in powershell.config.json *replaces* the default
// search path rather than extending it. Writing a bare entry into a file that
// had no PSModulePath key therefore removes $PSHOME/Modules — and with it
// every shipped module, which on Windows leaves a shell that cannot start.
//
// There is no way to extend the setting: a `%PSModulePath%` self-reference is
// written through literally rather than expanded (measured, not assumed), and
// expanding it here would bake one machine's absolute — and per-user — paths
// into a machine-wide file. So the ambiguous case is refused rather than
// silently doing the destructive thing.
fn effective_current(params: Value, doc: Value) -> Result[List[string], string] {
    let from_file = current_entries(doc)
    if !from_file.is_empty() { return Ok(from_file) }
    if !common::want_present(params)? { return Ok(from_file) }
    if common::param_str(params, "mode", "merge") != "merge" { return Ok(from_file) }
    Err("this file has no PSModulePath, and the setting replaces the default search path rather than extending it — merging one entry in would hide every shipped module. Use mode = :exact and list the directories the search path should consist of, including the ones that must survive")
}

fn desired_entries(params: Value, current: List[string]) -> Result[List[string], string] {
    let wanted = common::param_list(params, "entries")
    if wanted.is_empty() { return Err("'entries' must list at least one directory") }
    let mode = common::param_str(params, "mode", "merge")
    if !common::want_present(params)? {
        let kept: List[string] = []
        for entry in current {
            if !wanted.contains(entry) { kept.push(entry) }
        }
        return Ok(kept)
    }
    if mode == "exact" { return Ok(wanted) }
    if mode != "merge" { return Err("invalid 'mode' value '" + mode + "' (expected :merge or :exact)") }
    let merged: List[string] = []
    for entry in current { merged.push(entry) }
    for entry in wanted {
        if !merged.contains(entry) { merged.push(entry) }
    }
    Ok(merged)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    let resolved = config_file::config_path(params)?
    if resolved.is_none() {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let read = config_file::read_doc(config_file::user_root(params), resolved.unwrap())
    if read.is_err() { return Ok(CheckResult::NotConfigured) }
    let current = effective_current(params, read.unwrap())?
    // Order-sensitive: PSModulePath is a search order, not a set.
    if desired_entries(params, current)? == current { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = config_file::require_config_path(params)?
    let doc = config_file::read_doc(config_file::user_root(params), file)?
    let entries = desired_entries(params, effective_current(params, doc)?)?
    // An empty result means the setting no longer says anything, so the key
    // goes rather than being written as an empty string.
    let updated = if entries.is_empty() {
        config_file::drop_key(doc, "PSModulePath")
    } else {
        config_file::put(doc, "PSModulePath", Value::String(entries.join(sep())))
    }
    config_file::write_doc(config_file::user_root(params), file, updated)?
    Ok(ApplyResult::Success)
}
