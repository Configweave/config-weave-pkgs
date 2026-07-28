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

// WCL symbols are lower_snake_case; the settings they name are PascalCase.
fn pascal(symbol: string) -> string {
    let out = ""
    for word in symbol.split("_") {
        if word != "" { out = out + word.slice(0, 1).to_upper() + word.slice(1, word.len()) }
    }
    out
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

fn string_list(values: List[string]) -> Value {
    let items: List[Value] = []
    for v in values { items.push(Value::String(v)) }
    Value::List(items)
}

fn desired_doc(params: Value, doc: Value) -> Result[Value, string] {
    let updated = doc
    let level = param_str(params, "log_level", "unmanaged")
    if level != "unmanaged" {
        updated = put(updated, "LogLevel", Value::String(pascal(level)))
    }
    let identity = param_str(params, "log_identity", "")
    if identity != "" {
        updated = put(updated, "LogIdentity", Value::String(identity))
    }
    let manage = param_bool(params, "manage_lists", false)
    let channels = param_list(params, "log_channels")
    if manage || !channels.is_empty() {
        updated = put(updated, "LogChannels", string_list(channels))
    }
    let keywords = param_list(params, "log_keywords")
    if manage || !keywords.is_empty() {
        updated = put(updated, "LogKeywords", string_list(keywords))
    }
    Ok(updated)
}

fn check(params: Value) -> Result[CheckResult, string] {
    // Resolving the path runs the target PowerShell, which may not be
    // installed yet: run 1 checks every step before the install step has
    // applied. That is "not configured", not a failure.
    let file = ""
    if let Ok(resolved) = config_path(params) { file = resolved } else {
        return Ok(CheckResult::NotConfigured)
    }
    let doc = read_doc(file)?
    if json::to_string(desired_doc(params, doc)?) == json::to_string(doc) {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = config_path(params)?
    let doc = read_doc(file)?
    write_doc(file, desired_doc(params, doc)?)?
    Ok(ApplyResult::Success)
}
