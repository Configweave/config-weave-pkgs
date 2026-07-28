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

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
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

fn resolved_edition(edition: string) -> string {
    if edition != "auto" { return edition }
    if sys::family() == "windows" { "windows_powershell" } else { "pwsh" }
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
    let resolved = resolved_edition(edition)
    if resolved == "windows_powershell" { return "powershell" }
    pwsh_binary(resolved == "pwsh_preview")
}

fn dq(s: string) -> string { "\"" + s + "\"" }
fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// Every PowerShell invocation carries a timeout. A resource that can hang
// forever is a defect: the timeout kills the child and surfaces an Err, which
// the engine reports as a failed step naming this resource.
fn ps_argv(edition: string, file: string) -> string {
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file)
}

fn run_ps(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let out = shell::run(ps_argv(edition, file), Value::Map(#{ "timeout": Value::Int(300) }))
    fs::delete_dir(dir)?
    out
}

fn run_ps_streaming(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let out = shell::run_streaming(ps_argv(edition, file), Value::Map(#{ "timeout": Value::Int(2400) }))
    fs::delete_dir(dir)?
    out
}

fn ps_json(edition: string, script: string) -> Result[Value, string] {
    let out = run_ps(edition, script)?
    if !out.success { return Err(out.stderr.trim() + " " + out.stdout.trim()) }
    let text = out.stdout.trim()
    if text == "" { return Ok(Value::Null) }
    json::parse(text)
}

fn pascal(symbol: string) -> string {
    let out = ""
    for word in symbol.split("_") {
        if word != "" { out = out + word.slice(0, 1).to_upper() + word.slice(1, word.len()) }
    }
    out
}

fn config_path(params: Value) -> Result[string, string] {
    let explicit = param_str(params, "path", "")
    if explicit != "" { return Ok(explicit) }
    let edition = param_str(params, "edition", "pwsh")
    if param_str(params, "scope", "all_users") == "all_users" {
        let out = run_ps(edition, "Write-Output $PSHOME")
        if let Ok(result) = out {
            if result.success { return Ok(path::join(result.stdout.trim(), "powershell.config.json")) }
        }
        return Ok("")
    }
    let home = param_str(params, "home", "")
    if home != "" {
        if sys::family() == "windows" {
            return Ok(path::join(path::join(path::join(home, "Documents"), "PowerShell"), "powershell.config.json"))
        }
        return Ok(path::join(path::join(path::join(home, ".config"), "powershell"), "powershell.config.json"))
    }
    let out = run_ps(edition, "Write-Output (Split-Path -Parent $PROFILE.CurrentUserCurrentHost)")
    if let Ok(result) = out {
        if result.success { return Ok(path::join(result.stdout.trim(), "powershell.config.json")) }
    }
    Ok("")
}

fn gather(params: Value) -> Result[Value, string] {
    let file = config_path(params)?
    let empty: Map[string, Value] = #{}
    let none: List[Value] = []
    if file == "" || !fs::is_file(file) {
        return Ok(Value::Map(#{
            "exists": Value::Bool(false),
            "path": Value::String(file),
            "settings": Value::Map(empty),
            "execution_policy": Value::String(""),
            "psmodulepath": Value::String(""),
            "experimental_features": Value::List(none)
        }))
    }
    let text = fs::read(file)?.trim()
    let doc = if text == "" { Value::Map(#{}) } else { json::parse(text)? }
    let features: List[Value] = []
    if let Some(v) = doc.get("ExperimentalFeatures") {
        if let Some(items) = v.as_list() {
            for item in items { features.push(item) }
        }
    }
    Ok(Value::Map(#{
        "exists": Value::Bool(true),
        "path": Value::String(file),
        "settings": doc,
        "execution_policy": Value::String(doc.get("Microsoft.PowerShell:ExecutionPolicy").unwrap_or(Value::String("")).as_string().unwrap_or("")),
        "psmodulepath": Value::String(doc.get("PSModulePath").unwrap_or(Value::String("")).as_string().unwrap_or("")),
        "experimental_features": Value::List(features)
    }))
}
