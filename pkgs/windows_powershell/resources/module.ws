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

// Same invocation, but the child's output is streamed into the log as it
// arrives — a module install pulls from the network and can run for minutes.
fn run_ps_streaming(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let out = shell::run_streaming(ps_argv(edition, file), Value::Map(#{ "timeout": Value::Int(900) }))
    fs::delete_dir(dir)?
    out
}

fn pascal(symbol: string) -> string {
    let out = ""
    for word in symbol.split("_") {
        if word != "" { out = out + word.slice(0, 1).to_upper() + word.slice(1, word.len()) }
    }
    out
}

fn provider(params: Value) -> Result[string, string] {
    let requested = param_str(params, "provider", "auto")
    if requested == "psresourceget" { return Ok("psresourceget") }
    if requested == "powershellget" { return Ok("powershellget") }
    if requested != "auto" { return Err("invalid 'provider' value '" + requested + "'") }
    // Probing the cmdlet rather than listing the module: PSResourceGet ships
    // inside PowerShell 7 and stays usable even when PSModulePath has been
    // overridden so that Get-Module -ListAvailable no longer finds it. Getting
    // this wrong falls back to the v2 cmdlets, which under pwsh on Windows go
    // through the Windows PowerShell compatibility layer and can block.
    let probe = "if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {{ Write-Output 'psresourceget' }} else {{ Write-Output 'powershellget' }}"
    // A probe that cannot run at all means the target PowerShell is not
    // installed yet — run 1 checks every step before the install step has
    // applied — so fall back to the edition's usual generation.
    let out = run_ps(param_str(params, "edition", "auto"), probe)
    if let Ok(result) = out {
        if result.success {
            let detected = result.stdout.trim()
            if detected != "" { return Ok(detected) }
        }
    }
    if resolved_edition(param_str(params, "edition", "auto")) == "windows_powershell" { return Ok("powershellget") }
    Ok("psresourceget")
}

// Detection is deliberately Get-Module -ListAvailable rather than the
// provider's own inventory: Get-InstalledPSResource and Get-InstalledModule
// only know about resources those cmdlets installed, so an in-box or
// hand-copied module would read as missing and be reinstalled on every run.
// The provider still does the installing and uninstalling.
fn installed_versions(params: Value) -> Result[List[string], string] {
    let name = param_str(params, "name", "")
    let script = "@(Get-Module -ListAvailable -Name " + ps_q(name) + " | ForEach-Object {{ [string]$_.Version }}) -join \"`n\""
    let versions: List[string] = []
    // Not `?`: a missing binary is an Err from the spawn itself, and that is
    // the very case run 1 hits before the install step has applied.
    let probe = run_ps(param_str(params, "edition", "auto"), script)
    if probe.is_err() { return Ok(versions) }
    let out = probe.unwrap()
    // A machine without the edition installed reports nothing rather than
    // erroring: run 1 checks every step before the install step has run.
    if !out.success { return Ok(versions) }
    for line in out.stdout.split("\n") {
        let trimmed = line.trim()
        if trimmed != "" { versions.push(trimmed) }
    }
    Ok(versions)
}

// An exact version is matched exactly; a PSResourceGet range such as
// "[1.0.0, 3.0.0)" cannot be evaluated here, so any installed version
// satisfies it and the cmdlet is trusted to have resolved it.
fn is_range(version: string) -> bool {
    version.starts_with("[") || version.starts_with("(")
}

fn satisfied(params: Value, versions: List[string]) -> bool {
    if versions.is_empty() { return false }
    let version = param_str(params, "version", "")
    if version == "" { return true }
    if is_range(version) { return true }
    versions.contains(version)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let versions = installed_versions(params)?
    if !want_present(params)? {
        if versions.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if satisfied(params, versions) { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn install_script(params: Value, kind: string) -> string {
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    let repository = param_str(params, "repository", "")
    let scope = pascal(param_str(params, "scope", "current_user"))

    if kind == "psresourceget" {
        let args = " -Name " + ps_q(name) + " -Scope " + scope
        if version != "" { args = args + " -Version " + ps_q(version) }
        if repository != "" { args = args + " -Repository " + ps_q(repository) }
        if param_bool(params, "prerelease", false) { args = args + " -Prerelease" }
        if param_bool(params, "trust_repository", true) { args = args + " -TrustRepository" }
        if param_bool(params, "accept_license", false) { args = args + " -AcceptLicense" }
        if param_bool(params, "skip_dependency_check", false) { args = args + " -SkipDependencyCheck" }
        return "Import-Module Microsoft.PowerShell.PSResourceGet\nInstall-PSResource" + args
    }

    let args = " -Name " + ps_q(name) + " -Scope " + scope + " -Force"
    if version != "" { args = args + " -RequiredVersion " + ps_q(version) }
    if repository != "" { args = args + " -Repository " + ps_q(repository) }
    if param_bool(params, "prerelease", false) { args = args + " -AllowPrerelease" }
    if param_bool(params, "accept_license", false) { args = args + " -AcceptLicense" }
    if param_bool(params, "allow_clobber", false) { args = args + " -AllowClobber" }
    "Install-Module" + args
}

fn uninstall_script(params: Value, kind: string) -> string {
    let name = param_str(params, "name", "")
    if kind == "psresourceget" {
        return "Import-Module Microsoft.PowerShell.PSResourceGet\nUninstall-PSResource -Name " + ps_q(name) + " -Scope " + pascal(param_str(params, "scope", "current_user"))
    }
    "Uninstall-Module -Name " + ps_q(name) + " -AllVersions -Force"
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let edition = param_str(params, "edition", "auto")
    let kind = provider(params)?
    let present = want_present(params)?
    let script = if present { install_script(params, kind) } else { uninstall_script(params, kind) }
    let out = run_ps_streaming(edition, script)?
    if !out.success {
        let verb = if present { "installing" } else { "uninstalling" }
        return Err(verb + " module '" + name + "' failed: " + out.stderr.trim() + " " + out.stdout.trim())
    }
    Ok(ApplyResult::Success)
}
