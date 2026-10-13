// powershell.config.json: resolving which file, and reading and writing it.
use value
use fs
use path
use sys
use json
use common

// The per-user configuration directory, which PowerShell 7 keeps beside the
// user's profiles.
fn user_config_dir(home: string) -> string {
    if sys::family() == "windows" { return path::join(path::join(home, "Documents"), "PowerShell") }
    path::join(path::join(home, ".config"), "powershell")
}

// Resolve the powershell.config.json a resource owns. An explicit `path`
// wins, which is what lets the config resources run on a machine with no
// PowerShell 7 installed at all. None when the PowerShell that has to be
// asked is not installed.
fn config_path_for(params: Value, scope: string) -> Result[Option[string], string] {
    let explicit = common::param_str(params, "path", "")
    if explicit != "" { return Ok(Some(explicit)) }
    let edition = common::param_str(params, "edition", "pwsh")
    if scope == "all_users" {
        if let Some(home) = common::query(edition, "Write-Output $PSHOME")? {
            return Ok(Some(path::join(home, "powershell.config.json")))
        }
        return Ok(None)
    }
    let home = common::param_str(params, "home", "")
    if home != "" { return Ok(Some(path::join(user_config_dir(home), "powershell.config.json"))) }
    // No home: the account config-weave runs as, usually SYSTEM or root.
    if let Some(dir) = common::query(edition, "Write-Output (Split-Path -Parent $PROFILE.CurrentUserCurrentHost)")? {
        return Ok(Some(path::join(dir, "powershell.config.json")))
    }
    Ok(None)
}

fn config_path(params: Value) -> Result[Option[string], string] {
    config_path_for(params, common::param_str(params, "scope", "all_users"))
}

fn require_config_path(params: Value) -> Result[string, string] {
    if let Some(file) = config_path(params)? { return Ok(file) }
    Err("cannot resolve powershell.config.json: " + common::not_installed(common::param_str(params, "edition", "pwsh")))
}

// A missing or empty file is an empty document. A BOM (Windows PowerShell
// writes one) is skipped. A file that is not UTF-8 or not JSON is an error.
fn read_doc(p: string) -> Result[Value, string] {
    if !fs::is_file(p) { return Ok(Value::Map(#{})) }
    let text = fs::read(p)?
    if text.starts_with("\u{FEFF}") { text = text.slice(1, text.len()) }
    text = text.trim()
    if text == "" { return Ok(Value::Map(#{})) }
    let parsed = json::parse(text)
    if let Err(e) = parsed { return Err("'" + p + "' is not valid JSON: " + e) }
    parsed
}

fn write_doc(p: string, doc: Value) -> Result[unit, string] {
    let parent = path::parent(p)
    if parent != "" { fs::mkdir(parent)? }
    fs::write(p, json::to_string_pretty(doc) + "\n")
}

// json::to_string sorts its keys, so this is a stable structural comparison.
fn same_value(a: Value, b: Value) -> bool { json::to_string(a) == json::to_string(b) }

fn put(doc: Value, key: string, val: Value) -> Value {
    let m = if let Some(mm) = doc.as_map() { mm } else { #{} }
    m[key] = val
    Value::Map(m)
}

fn drop_key(doc: Value, key: string) -> Value {
    let m = if let Some(mm) = doc.as_map() { mm } else { #{} }
    let out: Map[string, Value] = #{}
    for existing in m.keys() {
        if existing != key { out[existing] = m[existing] }
    }
    Value::Map(out)
}

fn string_list(values: List[string]) -> Value {
    let items: List[Value] = []
    for v in values { items.push(Value::String(v)) }
    Value::List(items)
}

fn list_at(doc: Value, key: string) -> List[string] {
    let out: List[string] = []
    if let Some(v) = doc.get(key) {
        if let Some(items) = v.as_list() {
            for item in items {
                if let Some(s) = item.as_string() { out.push(s) }
            }
        }
    }
    out
}
