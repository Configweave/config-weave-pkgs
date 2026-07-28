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

// Enable-PSRemoting registers endpoints for whichever PowerShell runs it, so
// the edition is what picks between microsoft.powershell (5.1) and the
// PowerShell.7 endpoints — there is no switch that does it.
fn endpoint_filter(params: Value) -> string {
    let explicit = param_str(params, "configuration_name", "")
    if explicit != "" { return explicit }
    if resolved_edition(param_str(params, "edition", "auto")) == "windows_powershell" { return "microsoft.powershell" }
    "PowerShell.7*"
}

// True when at least one matching endpoint exists and is enabled.
fn endpoint_enabled(params: Value) -> Result[bool, string] {
    let filter = endpoint_filter(params)
    let script = "$c = @(Get-PSSessionConfiguration -Name " + ps_q(filter) + " -ErrorAction SilentlyContinue | Where-Object {{ $_.Enabled -eq $true -or $_.Enabled -eq 'True' }})\nif ($c.Count -gt 0) {{ Write-Output 'yes' }} else {{ Write-Output 'no' }}"
    let out = run_ps(param_str(params, "edition", "auto"), script)
    // WinRM not being configured at all is the "not enabled" answer, not an
    // error — and off Windows there is nothing to ask.
    if let Ok(result) = out {
        if result.success { return Ok(result.stdout.trim() == "yes") }
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if sys::family() != "windows" {
        return Err("WS-Management PowerShell remoting is only supported on Windows")
    }
    let enabled = endpoint_enabled(params)?
    if want_present(params)? {
        if enabled { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if enabled { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if sys::family() != "windows" {
        return Err("WS-Management PowerShell remoting is only supported on Windows")
    }
    let edition = param_str(params, "edition", "auto")
    let script = ""
    if want_present(params)? {
        let args = " -Force"
        if param_bool(params, "skip_network_profile_check", false) { args = args + " -SkipNetworkProfileCheck" }
        script = "Enable-PSRemoting" + args
    } else {
        script = "Get-PSSessionConfiguration -Name " + ps_q(endpoint_filter(params)) + " -ErrorAction SilentlyContinue | ForEach-Object {{ Disable-PSSessionConfiguration -Name $_.Name -Force }}"
    }
    let out = run_ps_streaming(edition, script)?
    if !out.success { return Err("configuring PowerShell remoting failed: " + out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
