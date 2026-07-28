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

fn empty_result() -> Value {
    let none: List[Value] = []
    let names: List[Value] = []
    Value::Map(#{
        "count": Value::Int(0),
        "provider": Value::String("none"),
        "names": Value::List(names),
        "repositories": Value::List(none)
    })
}

fn detect_provider(params: Value) -> string {
    let requested = param_str(params, "provider", "auto")
    if requested != "auto" { return requested }
    // Probing the cmdlet rather than listing the module: PSResourceGet ships
    // inside PowerShell 7 and stays usable even when PSModulePath has been
    // overridden so that Get-Module -ListAvailable no longer finds it. Getting
    // this wrong falls back to the v2 cmdlets, which under pwsh on Windows go
    // through the Windows PowerShell compatibility layer and can block.
    let probe = "if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {{ Write-Output 'psresourceget' }} else {{ Write-Output 'powershellget' }}"
    let out = run_ps(param_str(params, "edition", "auto"), probe)
    if let Ok(result) = out {
        if result.success {
            let detected = result.stdout.trim()
            if detected != "" { return detected }
        }
    }
    "none"
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = param_str(params, "edition", "auto")
    let kind = detect_provider(params)
    if kind == "none" { return Ok(empty_result()) }

    let script = if kind == "psresourceget" {
        "Import-Module Microsoft.PowerShell.PSResourceGet\n@(Get-PSResourceRepository | Select-Object @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.Uri}}}}, @{{n='trusted';e={{[bool]$_.Trusted}}}}, @{{n='priority';e={{[int]$_.Priority}}}}, @{{n='api_version';e={{[string]$_.ApiVersion}}}}) | ConvertTo-Json -Compress"
    } else {
        "@(Get-PSRepository | Select-Object @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.SourceLocation}}}}, @{{n='trusted';e={{$_.InstallationPolicy -eq 'Trusted'}}}}, @{{n='priority';e={{-1}}}}, @{{n='api_version';e={{''}}}}) | ConvertTo-Json -Compress"
    }
    let out = run_ps(edition, script)
    let entries: List[Value] = []
    let names: List[Value] = []
    if let Ok(result) = out {
        if result.success {
            let text = result.stdout.trim()
            if text != "" {
                let parsed = json::parse(text)?
                // Windows PowerShell collapses a single-element array into a
                // bare object, so both shapes have to be accepted.
                if let Some(items) = parsed.as_list() {
                    for item in items { entries.push(item) }
                } else if !parsed.is_null() {
                    entries.push(parsed)
                }
            }
        }
    }
    for entry in entries {
        if let Some(n) = entry.get("name") { names.push(n) }
    }
    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "provider": Value::String(if entries.is_empty() && kind == "none" { "none" } else { kind }),
        "names": Value::List(names),
        "repositories": Value::List(entries)
    }))
}
