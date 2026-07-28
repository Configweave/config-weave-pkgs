use value
use fs
use path
use shell
use sys
use json

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

// shell::powershell probes `powershell` before `pwsh`, so on Windows it can
// only ever reach Windows PowerShell 5.1. Every resource here picks its own
// binary instead.
// The MSI's PATH change is invisible to an already-running process, so a
// PowerShell installed earlier in this same run cannot be found by name.
// The well-known install roots are probed before falling back to PATH.
fn pwsh_binary(preview: bool) -> string {
    if sys::family() != "windows" {
        if preview { return "pwsh-preview" }
        return "pwsh"
    }
    let pattern = if preview { "C:\\Program Files\\PowerShell\\*-preview\\pwsh.exe" } else { "C:\\Program Files\\PowerShell\\*\\pwsh.exe" }
    if let Ok(found) = fs::glob(pattern) {
        let best = ""
        for candidate in found {
            if !preview && candidate.contains("-preview") { continue }
            best = candidate
        }
        if best != "" { return best }
    }
    "pwsh"
}

fn ps_exe(edition: string) -> string {
    if edition == "windows_powershell" { return "powershell" }
    if edition == "pwsh_preview" { return pwsh_binary(true) }
    if edition == "pwsh" { return pwsh_binary(false) }
    if sys::family() == "windows" { "powershell" } else { pwsh_binary(false) }
}

fn dq(s: string) -> string { "\"" + s + "\"" }

// -File with a temp .ps1 sidesteps shell-words quoting entirely, so the
// script may be multi-line and hold any quote character. -ExecutionPolicy is
// a Windows-only switch — and it is what keeps these invocations working
// under a policy this very package may have set.
// Every PowerShell invocation carries a timeout. A resource that can hang
// forever is a defect: the timeout kills the child and surfaces an Err, which
// the engine reports as a failed step naming this resource.
fn run_ps(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    let out = shell::run(dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file), Value::Map(#{ "timeout": Value::Int(300) }))
    fs::delete_dir(dir)?
    out
}

// Resolve the powershell.config.json this resource owns. An explicit `path`
// wins, which is what lets the config resources run on a machine with no
// PowerShell 7 installed at all.
fn config_path(params: Value) -> Result[string, string] {
    let explicit = param_str(params, "path", "")
    if explicit != "" { return Ok(explicit) }
    let edition = param_str(params, "edition", "pwsh")
    if param_str(params, "scope", "all_users") == "all_users" {
        let out = run_ps(edition, "Write-Output $PSHOME")?
        if !out.success { return Err("cannot resolve $PSHOME: " + out.stderr.trim()) }
        return Ok(path::join(out.stdout.trim(), "powershell.config.json"))
    }
    let home = param_str(params, "home", "")
    if home != "" {
        if sys::family() == "windows" {
            return Ok(path::join(path::join(path::join(home, "Documents"), "PowerShell"), "powershell.config.json"))
        }
        return Ok(path::join(path::join(path::join(home, ".config"), "powershell"), "powershell.config.json"))
    }
    let out = run_ps(edition, "Write-Output (Split-Path -Parent $PROFILE.CurrentUserCurrentHost)")?
    if !out.success { return Err("cannot resolve the user configuration directory: " + out.stderr.trim()) }
    Ok(path::join(out.stdout.trim(), "powershell.config.json"))
}

fn read_doc(p: string) -> Result[Value, string] {
    if !fs::is_file(p) { return Ok(Value::Map(#{})) }
    let text = fs::read(p)?.trim()
    if text == "" { return Ok(Value::Map(#{})) }
    json::parse(text)
}

fn write_doc(p: string, doc: Value) -> Result[unit, string] {
    let parent = path::parent(p)
    if parent != "" { fs::mkdir(parent)? }
    fs::write(p, json::to_string_pretty(doc) + "\n")
}

// json::to_string sorts its keys, so this is a stable structural comparison.
fn same_value(a: Value, b: Value) -> bool { json::to_string(a) == json::to_string(b) }

fn get_at(doc: Value, keys: List[string], idx: int) -> Option[Value] {
    let cur = doc.get(keys[idx])
    if cur.is_none() { return None }
    if idx == keys.len() - 1 { return cur }
    get_at(cur.unwrap(), keys, idx + 1)
}

fn set_at(doc: Value, keys: List[string], idx: int, val: Value) -> Value {
    let m = if let Some(mm) = doc.as_map() { mm } else { #{} }
    let k = keys[idx]
    if idx == keys.len() - 1 {
        m[k] = val
    } else {
        let child = if let Some(c) = m.get(k) { c } else { Value::Map(#{}) }
        m[k] = set_at(child, keys, idx + 1, val)
    }
    Value::Map(m)
}

// Rebuilds the map without the key rather than calling remove(), whose
// Option result would be dropped on the floor.
fn del_at(doc: Value, keys: List[string], idx: int) -> Value {
    let m = if let Some(mm) = doc.as_map() { mm } else { #{} }
    let k = keys[idx]
    let out: Map[string, Value] = #{}
    for existing in m.keys() {
        if existing != k {
            out[existing] = m[existing]
        } else if idx != keys.len() - 1 {
            out[existing] = del_at(m[existing], keys, idx + 1)
        }
    }
    Value::Map(out)
}

// Only dots split. A module-qualified key such as
// `Microsoft.PowerShell:ExecutionPolicy` is one literal key, which is what
// literal_key is for.
fn key_parts(params: Value) -> Result[List[string], string] {
    let key = param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    if param_bool(params, "literal_key", false) { return Ok([key]) }
    Ok(key.split("."))
}

fn desired_value(params: Value) -> Result[Value, string] {
    let raw = param_str(params, "value", "")
    let kind = param_str(params, "value_type", "string")
    if kind == "string" { return Ok(Value::String(raw)) }
    if kind == "bool" {
        let normal = raw.trim().to_lower()
        if normal == "true" { return Ok(Value::Bool(true)) }
        if normal == "false" { return Ok(Value::Bool(false)) }
        return Err("value_type :bool needs true or false, got '" + raw + "'")
    }
    if kind == "int" {
        if let Some(n) = raw.trim().parse_int() { return Ok(Value::Int(n)) }
        return Err("value_type :int needs a whole number, got '" + raw + "'")
    }
    if kind == "list" {
        let items: List[Value] = []
        for part in raw.split(",") {
            let trimmed = part.trim()
            if trimmed != "" { items.push(Value::String(trimmed)) }
        }
        return Ok(Value::List(items))
    }
    if kind == "json" { return json::parse(raw) }
    Err("unknown 'value_type' '" + kind + "'")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let keys = key_parts(params)?
    // Resolving the path runs the target PowerShell, which may not be
    // installed yet: run 1 checks every step before the install step has
    // applied. That is "not configured", not a failure.
    let file = ""
    if let Ok(resolved) = config_path(params) { file = resolved } else {
        if want_present(params)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let doc = read_doc(file)?
    let current = get_at(doc, keys, 0)
    if !want_present(params)? {
        if current.is_none() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if let Some(existing) = current {
        if same_value(existing, desired_value(params)?) { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let keys = key_parts(params)?
    let file = config_path(params)?
    let doc = read_doc(file)?
    let updated = if want_present(params)? {
        set_at(doc, keys, 0, desired_value(params)?)
    } else {
        del_at(doc, keys, 0)
    }
    write_doc(file, updated)?
    Ok(ApplyResult::Success)
}
