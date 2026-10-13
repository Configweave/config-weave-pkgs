use value
use common
use psget

fn name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    common::require("name", n)?
    common::no_wildcards("name", n)?
    Ok(n)
}

// The directory a scope installs into, as an expression evaluated by the
// target PowerShell itself — the same rules Install-PSResource and
// Install-Module follow.
fn scope_root_expr(params: Value) -> string {
    if common::param_str(params, "scope", "current_user") == "all_users" {
        return "$(if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path $env:ProgramFiles 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path $env:ProgramFiles 'PowerShell\\Modules' }} else {{ '/usr/local/share/powershell/Modules' }})"
    }
    "$(if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\\Modules' }} else {{ Join-Path $HOME '.local/share/powershell/Modules' }})"
}

// Detection is Get-Module -ListAvailable rather than the provider's own
// inventory: Get-InstalledPSResource and Get-InstalledModule only know about
// resources those cmdlets installed, so a hand-copied module would read as
// missing and be reinstalled on every run. It is filtered to the scope's
// own directory, because that is the only place install and uninstall act.
// A prerelease version carries its label (1.2.0-beta1), read from the
// manifest's PrivateData, so a prerelease pin can match.
fn installed_versions(params: Value) -> Result[List[string], string] {
    let script = "$root = " + scope_root_expr(params) + "\n$prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar\n@(Get-Module -ListAvailable -Name " + common::ps_q(name(params)?) + " | Where-Object {{ $_.ModuleBase.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }} | ForEach-Object {{ $v = [string]$_.Version; $p = $null; if ($_.PrivateData -is [hashtable] -and $_.PrivateData.PSData -is [hashtable]) {{ $p = $_.PrivateData.PSData.Prerelease }}; if ($p) {{ $v + '-' + $p }} else {{ $v }} }}) -join \"`n\""
    if let Some(text) = common::query(common::param_str(params, "edition", "auto"), script)? { return Ok(common::lines_of(text)) }
    // Not installed yet: run 1 checks every step before the install step.
    let none: List[string] = []
    Ok(none)
}

// An exact version is matched exactly (prerelease labels case-insensitively,
// as NuGet compares them); a range cannot be evaluated here, so any
// installed version satisfies it and the cmdlet is trusted to have resolved
// it.
fn satisfied(params: Value, versions: List[string]) -> bool {
    if versions.is_empty() { return false }
    let version = common::param_str(params, "version", "")
    if version == "" || psget::is_range(version) { return true }
    for v in versions {
        if psget::version_eq(v, version) { return true }
    }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let versions = installed_versions(params)?
    if !common::want_present(params)? {
        if versions.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if satisfied(params, versions) { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn install_script(params: Value, kind: string) -> Result[string, string] {
    let n = name(params)?
    let version = common::param_str(params, "version", "")
    let repository = common::param_str(params, "repository", "")
    let scope = common::pascal(common::param_str(params, "scope", "current_user"))

    if kind == "psresourceget" {
        let args = " -Name " + common::ps_q(n) + " -Scope " + scope
        if version != "" { args = args + " -Version " + common::ps_q(version) }
        if repository != "" { args = args + " -Repository " + common::ps_q(repository) }
        if common::param_bool(params, "prerelease", false) { args = args + " -Prerelease" }
        if common::param_bool(params, "trust_repository", false) { args = args + " -TrustRepository" }
        if common::param_bool(params, "accept_license", false) { args = args + " -AcceptLicense" }
        if common::param_bool(params, "skip_dependency_check", false) { args = args + " -SkipDependencyCheck" }
        return Ok(psget::import_line(kind) + "Install-PSResource" + args)
    }

    // Install-Module has no per-call trust switch: -Force is what skips the
    // untrusted-repository prompt, so it is only passed when trust is asked
    // for. Without it an untrusted repository fails non-interactively.
    let args = " -Name " + common::ps_q(n) + " -Scope " + scope
    if common::param_bool(params, "trust_repository", false) { args = args + " -Force" }
    if version != "" { args = args + " -RequiredVersion " + common::ps_q(version) }
    if repository != "" { args = args + " -Repository " + common::ps_q(repository) }
    if common::param_bool(params, "prerelease", false) { args = args + " -AllowPrerelease" }
    if common::param_bool(params, "accept_license", false) { args = args + " -AcceptLicense" }
    if common::param_bool(params, "allow_clobber", false) { args = args + " -AllowClobber" }
    Ok(psget::v2_bootstrap() + "Install-Module" + args)
}

// Removes every version found under the scope's directory — the same set
// check looks at.
fn uninstall_script(params: Value, kind: string) -> Result[string, string] {
    let n = name(params)?
    if kind == "psresourceget" {
        return Ok(psget::import_line(kind) + "Uninstall-PSResource -Name " + common::ps_q(n) + " -Scope " + common::pascal(common::param_str(params, "scope", "current_user")))
    }
    Ok("$root = " + scope_root_expr(params) + "\n$prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar\nGet-InstalledModule -Name " + common::ps_q(n) + " -AllVersions -ErrorAction SilentlyContinue | Where-Object {{ $_.InstalledLocation.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }} | Uninstall-Module -Force")
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let n = name(params)?
    let edition = common::param_str(params, "edition", "auto")
    if !common::ps_installed(edition) { return Err(common::not_installed(edition)) }
    let kind = psget::provider(params)?
    let present = common::want_present(params)?
    let script = if present { install_script(params, kind)? } else { uninstall_script(params, kind)? }
    let out = common::run_ps_streaming(edition, script, 900)?
    if !out.success {
        let verb = if present { "installing" } else { "uninstalling" }
        return Err(common::failure(verb + " module '" + n + "'", out))
    }
    Ok(ApplyResult::Success)
}
