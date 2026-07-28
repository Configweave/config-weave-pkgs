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
        "found": Value::Bool(false),
        "names": Value::List(names),
        "modules": Value::List(none)
    })
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = param_str(params, "edition", "auto")
    let name = param_str(params, "name", "")
    let filter = if name == "" { "*" } else { name }
    // Get-Module -ListAvailable rather than the provider inventory: it sees
    // in-box and hand-installed modules too, which is what "installed" means.
    let script = "@(Get-Module -ListAvailable -Name " + ps_q(filter) + " | Select-Object @{{n='name';e={{[string]$_.Name}}}}, @{{n='version';e={{[string]$_.Version}}}}, @{{n='repository';e={{[string]$_.RepositorySourceLocation}}}}, @{{n='path';e={{[string]$_.ModuleBase}}}}) | ConvertTo-Json -Compress"
    let out = run_ps(edition, script)
    let entries: List[Value] = []
    if let Ok(result) = out {
        if result.success {
            let text = result.stdout.trim()
            if text != "" {
                let parsed = json::parse(text)?
                if let Some(items) = parsed.as_list() {
                    for item in items { entries.push(item) }
                } else if !parsed.is_null() {
                    entries.push(parsed)
                }
            }
        }
    }
    if entries.is_empty() { return Ok(empty_result()) }

    // Scope filtering is a path-prefix test: a module under the user's module
    // directory belongs to :current_user, anything else to :all_users.
    let scope = param_str(params, "scope", "any")
    let kept: List[Value] = []
    let user_root = ""
    if scope != "any" {
        let probe = run_ps(edition, "if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\\Modules' }} else {{ Join-Path $HOME '.local/share/powershell/Modules' }}")
        if let Ok(result) = probe {
            if result.success { user_root = result.stdout.trim().replace("\\", "/") }
        }
    }
    for entry in entries {
        if scope == "any" {
            kept.push(entry)
            continue
        }
        let where = entry.get("path").unwrap_or(Value::String("")).as_string().unwrap_or("").replace("\\", "/")
        let in_user = user_root != "" && where.starts_with(user_root)
        if scope == "current_user" && in_user { kept.push(entry) }
        if scope == "all_users" && !in_user { kept.push(entry) }
    }

    let names: List[Value] = []
    for entry in kept {
        if let Some(n) = entry.get("name") { names.push(n) }
    }
    Ok(Value::Map(#{
        "count": Value::Int(kept.len()),
        "found": Value::Bool(!kept.is_empty()),
        "names": Value::List(names),
        "modules": Value::List(kept)
    }))
}
