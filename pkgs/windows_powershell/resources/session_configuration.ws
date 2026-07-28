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
    let out = shell::run_streaming(ps_argv(edition, file), Value::Map(#{ "timeout": Value::Int(600) }))
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

fn current_endpoint(params: Value) -> Result[Value, string] {
    let name = param_str(params, "name", "")
    let script = "Get-PSSessionConfiguration -Name " + ps_q(name) + " -ErrorAction SilentlyContinue | Select-Object -First 1 @{{n='name';e={{[string]$_.Name}}}}, @{{n='access';e={{[string]$_.Permission}}}}, @{{n='psversion';e={{[string]$_.PSVersion}}}} | ConvertTo-Json -Compress"
    // A machine with no WinRM configured answers "no such endpoint", which is
    // a fact rather than a failure.
    let out = run_ps(param_str(params, "edition", "auto"), script)
    if let Ok(result) = out {
        if result.success {
            let text = result.stdout.trim()
            if text == "" { return Ok(Value::Null) }
            return json::parse(text)
        }
    }
    Ok(Value::Null)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if sys::family() != "windows" {
        return Err("WinRM session configurations are only supported on Windows")
    }
    let exists = !current_endpoint(params)?.is_null()
    if want_present(params)? {
        if exists { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if exists { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if sys::family() != "windows" {
        return Err("WinRM session configurations are only supported on Windows")
    }
    let edition = param_str(params, "edition", "auto")

    if !want_present(params)? {
        let script = "Unregister-PSSessionConfiguration -Name " + ps_q(name) + " -Force -NoServiceRestart"
        let out = run_ps(edition, script)?
        if !out.success { return Err("unregistering the session configuration '" + name + "' failed: " + out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }

    let args = " -Name " + ps_q(name) + " -Force -NoServiceRestart"
    let file = param_str(params, "path", "")
    if file != "" { args = args + " -Path " + ps_q(file) }
    let session_type = param_str(params, "session_type", "unmanaged")
    if session_type != "unmanaged" { args = args + " -SessionType " + pascal(session_type) }
    let access = param_str(params, "access_mode", "unmanaged")
    if access != "unmanaged" { args = args + " -AccessMode " + pascal(access) }
    let startup = param_str(params, "startup_script", "")
    if startup != "" { args = args + " -StartupScript " + ps_q(startup) }
    let limit = param_int(params, "max_received_data_size_mb", -1)
    if limit >= 0 { args = args + " -MaximumReceivedDataSizePerCommandMB " + str(limit) }
    let psversion = param_str(params, "psversion", "")
    if psversion != "" { args = args + " -PSVersion " + psversion }

    let out = run_ps_streaming(edition, "Register-PSSessionConfiguration" + args)?
    if !out.success { return Err("registering the session configuration '" + name + "' failed: " + out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
