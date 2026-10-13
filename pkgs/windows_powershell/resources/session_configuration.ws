use value
use hash
use json
use sys
use common

fn name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    common::require("name", n)?
    common::no_wildcards("name", n)?
    Ok(n)
}

fn edition(params: Value) -> string { common::param_str(params, "edition", "auto") }

fn validate(params: Value) -> Result[unit, string] {
    if sys::family() != "windows" {
        return Err("WinRM session configurations are only supported on Windows")
    }
    name(params)?
    let winps = common::resolved_edition(edition(params)) == "windows_powershell"
    let psversion = common::param_str(params, "psversion", "")
    common::version_chars("psversion", psversion)?
    // PowerShell 7's Register-PSSessionConfiguration rejects -PSVersion and
    // has no -SessionType at all.
    if psversion != "" && !winps { return Err("'psversion' is only supported by Windows PowerShell endpoints (edition :windows_powershell)") }
    if common::param_str(params, "session_type", "unmanaged") != "unmanaged" && !winps {
        return Err("'session_type' is only supported by Windows PowerShell endpoints (edition :windows_powershell)")
    }
    Ok(())
}

// Projected to plain scalars in PowerShell. Access mode is not a property:
// :disabled is Enabled = false, and :local is an access-denied entry for the
// NETWORK SID (S-1-5-2) in the endpoint's security descriptor, which is what
// -AccessMode Local adds. The .pssc an endpoint was registered from is
// copied verbatim, so its hash identifies the content.
fn current_endpoint(params: Value) -> Result[Option[Value], string] {
    let script = "$name = " + common::ps_q(name(params)?) + "\n$c = @(Get-PSSessionConfiguration -ErrorAction Stop | Where-Object {{ $_.Name -eq $name }}) | Select-Object -First 1\nif ($null -eq $c) {{ return }}\n$sd = New-Object System.Security.AccessControl.CommonSecurityDescriptor($false, $false, [string]$c.SecurityDescriptorSddl)\n$net = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-2')\n$deny = @($sd.DiscretionaryAcl | Where-Object {{ [string]$_.AceQualifier -eq 'AccessDenied' -and $_.SecurityIdentifier -eq $net }}).Count -gt 0\n$file = [string]$c.ConfigFilePath\n$hash = ''\nif ($file -ne '' -and (Test-Path -LiteralPath $file)) {{ $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }}\n[pscustomobject]@{{ enabled = ([string]$c.Enabled).ToLower() -eq 'true'; deny_network = $deny; startup_script = [string]$c.startupscript; max_mb = [string]$c.psmaximumreceiveddatasizepercommandmb; psversion = [string]$c.PSVersion; session_type = [string]$c.sessiontype; has_config = $file -ne ''; config_hash = $hash }} | ConvertTo-Json -Compress"
    if let Some(text) = common::query(edition(params), script)? {
        if text == "" { return Ok(None) }
        return Ok(Some(json::parse(text)?))
    }
    // The edition is not installed yet: run 1 checks every step before the
    // install step has applied, and nothing can be registered without it.
    Ok(None)
}

fn field(v: Value, key: string) -> string {
    if let Some(x) = v.get(key) {
        if let Some(s) = x.as_string() { return s }
        if let Some(b) = x.as_bool() { return if b { "true" } else { "false" } }
    }
    ""
}

fn major_minor(version: string) -> string {
    let parts = version.trim().split(".")
    if parts.len() >= 2 { return parts[0] + "." + parts[1] }
    version.trim()
}

// The name of the first setting that differs, or "" when the endpoint
// matches every managed param.
fn drift(params: Value, c: Value) -> Result[string, string] {
    let enabled = field(c, "enabled") == "true"
    let deny_network = field(c, "deny_network") == "true"
    let access = common::param_str(params, "access_mode", "unmanaged")
    if access == "disabled" && enabled { return Ok("access_mode") }
    if access == "local" && (!enabled || !deny_network) { return Ok("access_mode") }
    if access == "remote" && (!enabled || deny_network) { return Ok("access_mode") }

    // Session configuration paths are Windows paths: compared case-insensitively.
    let startup = common::param_str(params, "startup_script", "")
    if field(c, "startup_script").to_lower() != startup.to_lower() { return Ok("startup_script") }

    let limit = common::param_int(params, "max_received_data_size_mb", -1)
    if limit >= 0 {
        let have = field(c, "max_mb").trim().parse_float()
        if have.is_none() || have.unwrap() != float(limit) { return Ok("max_received_data_size_mb") }
    }

    let psversion = common::param_str(params, "psversion", "")
    if psversion != "" && major_minor(field(c, "psversion")) != major_minor(psversion) { return Ok("psversion") }

    let session_type = common::param_str(params, "session_type", "unmanaged")
    let workflow = field(c, "session_type").to_lower() == "workflow"
    if session_type == "workflow" && !workflow { return Ok("session_type") }
    if session_type == "default_remote_shell" && workflow { return Ok("session_type") }

    let file = common::param_str(params, "path", "")
    let has_config = field(c, "has_config") == "true"
    if file == "" {
        if has_config { return Ok("path") }
    } else {
        if !has_config { return Ok("path") }
        if field(c, "config_hash").to_lower() != hash::sha256_file(file)?.to_lower() { return Ok("path") }
    }
    Ok("")
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let current = current_endpoint(params)?
    if !common::want_present(params)? {
        if current.is_none() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if current.is_none() { return Ok(CheckResult::NotConfigured) }
    if drift(params, current.unwrap())? == "" { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn register_args(params: Value) -> Result[string, string] {
    let args = " -Name " + common::ps_q(name(params)?) + " -Force -NoServiceRestart"
    let file = common::param_str(params, "path", "")
    if file != "" { args = args + " -Path " + common::ps_q(file) }
    let session_type = common::param_str(params, "session_type", "unmanaged")
    if session_type != "unmanaged" { args = args + " -SessionType " + common::pascal(session_type) }
    let access = common::param_str(params, "access_mode", "unmanaged")
    if access != "unmanaged" { args = args + " -AccessMode " + common::pascal(access) }
    let startup = common::param_str(params, "startup_script", "")
    if startup != "" { args = args + " -StartupScript " + common::ps_q(startup) }
    let limit = common::param_int(params, "max_received_data_size_mb", -1)
    if limit >= 0 { args = args + " -MaximumReceivedDataSizePerCommandMB " + str(limit) }
    let psversion = common::param_str(params, "psversion", "")
    if psversion != "" { args = args + " -PSVersion " + common::ps_q(psversion) }
    Ok(args)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let n = name(params)?
    let ed = edition(params)
    if !common::ps_installed(ed) { return Err(common::not_installed(ed)) }
    let exists = current_endpoint(params)?.is_some()
    let unregister = "Unregister-PSSessionConfiguration -Name " + common::ps_q(n) + " -Force -NoServiceRestart"

    if !common::want_present(params)? {
        if !exists { return Ok(ApplyResult::Success) }
        let out = common::run_ps(ed, unregister)?
        if !out.success { return Err(common::failure("unregistering the session configuration '" + n + "'", out)) }
        return Ok(ApplyResult::Success)
    }

    // Several settings (the .pssc, the session type) can only be given at
    // registration, so an endpoint that drifted is re-registered whole.
    let script = if exists { unregister + "\n" } else { "" }
    script = script + "Register-PSSessionConfiguration" + register_args(params)?
    let out = common::run_ps_streaming(ed, script, 600)?
    if !out.success { return Err(common::failure("registering the session configuration '" + n + "'", out)) }
    Ok(ApplyResult::Success)
}
