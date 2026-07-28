use value
use fs
use path
use shell
use sys
use http

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
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

// Windows PowerShell keeps its per-user profiles under Documents\WindowsPowerShell;
// PowerShell 7 uses Documents\PowerShell on Windows and ~/.config/powershell
// elsewhere. `home` is honoured because the testlab guest agent runs execs
// with HOME=/, so an ambient $HOME cannot be trusted.
fn profile_dir(params: Value, all_users: bool) -> Result[string, string] {
    let edition = param_str(params, "edition", "auto")
    if all_users {
        let out = run_ps(edition, "Write-Output $PSHOME")?
        if !out.success { return Err("cannot resolve $PSHOME: " + out.stderr.trim()) }
        return Ok(out.stdout.trim())
    }
    let home = param_str(params, "home", "")
    if home != "" {
        if sys::family() == "windows" {
            let folder = if resolved_edition(edition) == "windows_powershell" { "WindowsPowerShell" } else { "PowerShell" }
            return Ok(path::join(path::join(home, "Documents"), folder))
        }
        return Ok(path::join(path::join(home, ".config"), "powershell"))
    }
    let out = run_ps(edition, "Write-Output (Split-Path -Parent $PROFILE.CurrentUserCurrentHost)")?
    if !out.success { return Err("cannot resolve the user profile directory: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn profile_path(params: Value) -> Result[string, string] {
    let explicit = param_str(params, "path", "")
    if explicit != "" { return Ok(explicit) }
    let scope = param_str(params, "scope", "current_user_current_host")
    let valid = ["all_users_all_hosts", "all_users_current_host", "current_user_all_hosts", "current_user_current_host"]
    if !valid.contains(scope) { return Err("invalid 'scope' value '" + scope + "'") }
    let dir = profile_dir(params, scope.starts_with("all_users"))?
    if scope.ends_with("all_hosts") { return Ok(path::join(dir, "profile.ps1")) }
    Ok(path::join(dir, param_str(params, "host", "Microsoft.PowerShell") + "_profile.ps1"))
}

fn desired_content(params: Value) -> Result[string, string] {
    let source = param_str(params, "source", "")
    if source == "" { return Ok(param_str(params, "content", "")) }
    if source.starts_with("http://") || source.starts_with("https://") {
        let response = http::get(source, Value::Null)?
        if response.status < 200 || response.status >= 300 {
            return Err("GET " + source + " returned " + str(response.status))
        }
        return Ok(response.body)
    }
    if !fs::is_file(source) { return Err("source file '" + source + "' does not exist") }
    fs::read(source)
}

fn check(params: Value) -> Result[CheckResult, string] {
    // Resolving the profile path runs the target PowerShell, which may not
    // be installed yet: run 1 checks every step before the install step has
    // applied. That is "not configured", not a failure.
    let file = ""
    if let Ok(resolved) = profile_path(params) { file = resolved } else {
        if want_present(params)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !want_present(params)? {
        if fs::exists(file) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(file) { return Ok(CheckResult::NotConfigured) }
    if fs::read(file)? == desired_content(params)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = profile_path(params)?
    if !want_present(params)? {
        if fs::exists(file) { fs::delete(file)? }
        return Ok(ApplyResult::Success)
    }
    let parent = path::parent(file)
    if parent != "" { fs::mkdir(parent)? }
    fs::write(file, desired_content(params)?)?
    Ok(ApplyResult::Success)
}
