use value
use fs
use path

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn begin_marker(label: string) -> string { "# BEGIN " + label }
fn end_marker(label: string) -> string { "# END " + label }

// The exact managed segment: BEGIN marker, the block body (trailing
// newline trimmed for a stable shape), then the END marker.
fn segment(label: string, block: string) -> string {
    begin_marker(label) + "\n" + block.trim_end() + "\n" + end_marker(label)
}

// Return `text` with any existing BEGIN..END region (and its trailing
// newline) removed.
fn strip_region(text: string, label: string) -> string {
    let begin = begin_marker(label)
    let end = end_marker(label)
    let bi = text.find(begin)
    if bi.is_none() { return text }
    let ei = text.find(end)
    if ei.is_none() { return text }
    let b = bi.unwrap()
    let stop_marker = ei.unwrap() + end.len()
    let stop = if stop_marker < text.len() && text.slice(stop_marker, stop_marker + 1) == "\n" {
        stop_marker + 1
    } else {
        stop_marker
    }
    text.slice(0, b) + text.slice(stop, text.len())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    let label = param_str(params, "marker_label", "config-weave")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        if !fs::exists(p) { return Ok(CheckResult::AlreadyConfigured) }
        if fs::read(p)?.contains(begin_marker(label)) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let block = param_str(params, "block", "")
    if block == "" { return Err("missing 'block' parameter") }
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    if fs::read(p)?.contains(segment(label, block)) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    let label = param_str(params, "marker_label", "config-weave")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        fs::write(p, strip_region(fs::read(p)?, label))?
        return Ok(ApplyResult::Success)
    }
    let block = param_str(params, "block", "")
    if block == "" { return Err("missing 'block' parameter") }
    if !fs::exists(p) {
        if !param_bool(params, "create", true) { return Err("file does not exist and create is false") }
        fs::mkdir(path::parent(p))?
        fs::write(p, "")?
    }
    let cleaned = strip_region(fs::read(p)?, label)
    let sep = if cleaned == "" || cleaned.ends_with("\n") { "" } else { "\n" }
    fs::write(p, cleaned + sep + segment(label, block) + "\n")?
    Ok(ApplyResult::Success)
}
