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

fn param_list(params: Value, key: string) -> List[string] {
    let out: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(items) = v.as_list() {
            for item in items {
                if let Some(s) = item.as_string() { out.push(s) }
            }
        }
    }
    out
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

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
    if !want_present(params)? { return Ok(from_file) }
    if param_str(params, "mode", "merge") != "merge" { return Ok(from_file) }
    Err("this file has no PSModulePath, and the setting replaces the default search path rather than extending it — merging one entry in would hide every shipped module. Use mode = :exact and list the directories the search path should consist of, including the ones that must survive")
}

fn desired_entries(params: Value, current: List[string]) -> Result[List[string], string] {
    let wanted = param_list(params, "entries")
    if wanted.is_empty() { return Err("'entries' must list at least one directory") }
    let mode = param_str(params, "mode", "merge")
    if !want_present(params)? {
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
    // Resolving the path runs the target PowerShell, which may not be
    // installed yet: run 1 checks every step before the install step has
    // applied. That is "not configured", not a failure.
    let file = ""
    if let Ok(resolved) = config_path(params) { file = resolved } else {
        if want_present(params)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let doc = read_doc(file)?
    let current = effective_current(params, doc)?
    // Order-sensitive: PSModulePath is a search order, not a set.
    if desired_entries(params, current)? == current { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = config_path(params)?
    let doc = read_doc(file)?
    let entries = desired_entries(params, effective_current(params, doc)?)?
    // An empty result means the setting no longer says anything, so the key
    // goes rather than being written as an empty string.
    let updated = if entries.is_empty() {
        drop_key(doc, "PSModulePath")
    } else {
        put(doc, "PSModulePath", Value::String(entries.join(sep())))
    }
    write_doc(file, updated)?
    Ok(ApplyResult::Success)
}
