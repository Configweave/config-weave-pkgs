use value
use common
use psget

fn name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    common::require("name", n)?
    common::no_wildcards("name", n)?
    Ok(n)
}

// Unlike a module there is no Get-Module -ListAvailable for scripts, so the
// provider's own inventory is the only thing that knows. It is filtered to
// the requested scope, the only place install and uninstall act.
fn installed_versions(params: Value, kind: string) -> Result[List[string], string] {
    let n = common::ps_q(name(params)?)
    let all_users = common::param_str(params, "scope", "current_user") == "all_users"
    let script = if kind == "psresourceget" {
        let scope = if all_users { "AllUsers" } else { "CurrentUser" }
        psget::import_line(kind) + "@(Get-InstalledPSResource -Name " + n + " -Scope " + scope + " -ErrorAction SilentlyContinue | Where-Object {{ [string]$_.Type -eq 'Script' }} | ForEach-Object {{ if ($_.Prerelease) {{ [string]$_.Version + '-' + $_.Prerelease }} else {{ [string]$_.Version }} }}) -join \"`n\""
    } else {
        let root = if all_users {
            "$(if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path $env:ProgramFiles 'WindowsPowerShell\\Scripts' }} elseif ($IsWindows) {{ Join-Path $env:ProgramFiles 'PowerShell\\Scripts' }} else {{ '/usr/local/share/powershell/Scripts' }})"
        } else {
            "$(if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path ([Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')) 'WindowsPowerShell\\Scripts' }} elseif ($IsWindows) {{ Join-Path ([Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')) 'PowerShell\\Scripts' }} else {{ Join-Path $HOME '.local/share/powershell/Scripts' }})"
        }
        "$prefix = (" + root + ") + [IO.Path]::DirectorySeparatorChar\n@(Get-InstalledScript -Name " + n + " -ErrorAction SilentlyContinue | Where-Object {{ ($_.InstalledLocation + [IO.Path]::DirectorySeparatorChar).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }} | ForEach-Object {{ [string]$_.Version }}) -join \"`n\""
    }
    if let Some(text) = common::query(common::param_str(params, "edition", "auto"), script)? { return Ok(common::lines_of(text)) }
    // Not installed yet: run 1 checks every step before the install step.
    let none: List[string] = []
    Ok(none)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let versions = installed_versions(params, psget::provider(params)?)?
    if !common::want_present(params)? {
        if versions.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if versions.is_empty() { return Ok(CheckResult::NotConfigured) }
    let version = common::param_str(params, "version", "")
    if version == "" || psget::is_range(version) { return Ok(CheckResult::AlreadyConfigured) }
    for v in versions {
        if psget::version_eq(v, version) { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let n = name(params)?
    let edition = common::param_str(params, "edition", "auto")
    if !common::ps_installed(edition) { return Err(common::not_installed(edition)) }
    let kind = psget::provider(params)?
    let present = common::want_present(params)?
    let version = common::param_str(params, "version", "")
    let repository = common::param_str(params, "repository", "")
    let scope = common::pascal(common::param_str(params, "scope", "current_user"))
    let trust = common::param_bool(params, "trust_repository", false)

    let script = ""
    if kind == "psresourceget" {
        if present {
            let args = " -Name " + common::ps_q(n) + " -Scope " + scope
            if version != "" { args = args + " -Version " + common::ps_q(version) }
            if repository != "" { args = args + " -Repository " + common::ps_q(repository) }
            if common::param_bool(params, "prerelease", false) { args = args + " -Prerelease" }
            if trust { args = args + " -TrustRepository" }
            script = psget::import_line(kind) + "Install-PSResource" + args
        } else {
            script = psget::import_line(kind) + "Uninstall-PSResource -Name " + common::ps_q(n) + " -Scope " + scope
        }
    } else if present {
        // Install-Script has no per-call trust switch; -Force is what skips
        // the untrusted-repository prompt, so it follows trust_repository.
        let args = " -Name " + common::ps_q(n) + " -Scope " + scope
        if trust { args = args + " -Force" }
        if version != "" { args = args + " -RequiredVersion " + common::ps_q(version) }
        if repository != "" { args = args + " -Repository " + common::ps_q(repository) }
        if common::param_bool(params, "prerelease", false) { args = args + " -AllowPrerelease" }
        script = psget::v2_bootstrap() + "Install-Script" + args
    } else {
        script = "Uninstall-Script -Name " + common::ps_q(n) + " -Force"
    }

    let out = common::run_ps_streaming(edition, script, 900)?
    if !out.success {
        let verb = if present { "installing" } else { "uninstalling" }
        return Err(common::failure(verb + " script '" + n + "'", out))
    }
    Ok(ApplyResult::Success)
}
