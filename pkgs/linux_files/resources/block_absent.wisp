use value
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn begin_marker(label: string) -> string { "# BEGIN " + label }
fn end_marker(label: string) -> string { "# END " + label }

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
    if !fs::exists(p) { return Ok(CheckResult::AlreadyConfigured) }
    if fs::read(p)?.contains(begin_marker(label)) { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    let label = param_str(params, "marker_label", "config-weave")
    if p == "" { return Err("missing 'path' parameter") }
    if !fs::exists(p) { return Ok(ApplyResult::Success) }
    fs::write(p, strip_region(fs::read(p)?, label))?
    Ok(ApplyResult::Success)
}
