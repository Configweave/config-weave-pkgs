use value
use shell
use service
use log

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

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn installed(name: string) -> Result[bool, string] {
    let st = ps_out(
        "if (Get-Service -Name " + ps_q(name) + " -ErrorAction SilentlyContinue) {{ 'PRESENT' }} else {{ 'ABSENT' }}"
    )?
    Ok(st == "PRESENT")
}

fn startup_type(startup: string) -> Result[string, string] {
    if startup == "automatic" { return Ok("Automatic") }
    if startup == "manual" { return Ok("Manual") }
    if startup == "disabled" { return Ok("Disabled") }
    Err("invalid 'startup' value '" + startup + "' (expected automatic, manual or disabled)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let exists = installed(name)?
    if !want_present(params)? {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if param_str(params, "path", "") == "" { return Err("'path' is required when ensure is :present") }
    // path/display_name/description/startup/user are create-only; an existing
    // registration satisfies this resource. Manage runtime state and startup
    // drift with service_state / service_startup.
    if exists { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        if !installed(name)? { return Ok(ApplyResult::Success) }
        // Best-effort stop first; a service that is already stopped (or
        // refuses to stop) should not block deletion.
        let stopped = service::stop(name)
        if stopped.is_err() { log::info("service '" + name + "' not stopped before delete: " + stopped.unwrap_err()) }
        ps_run(
            "sc.exe delete " + ps_q(name) + " | Out-Null; " +
            "if ($LASTEXITCODE -ne 0) {{ throw \"sc.exe delete exited $LASTEXITCODE\" }}"
        )?
        return Ok(ApplyResult::Success)
    }
    let path = param_str(params, "path", "")
    if path == "" { return Err("'path' is required when ensure is :present") }
    let st = startup_type(param_str(params, "startup", "automatic"))?
    let display = param_str(params, "display_name", "")
    let desc = param_str(params, "description", "")
    let user = param_str(params, "user", "")
    let pw = param_str(params, "password", "")
    // Built-in accounts have no password; PSCredential still needs a (then
    // empty) SecureString.
    let secure = if pw == "" {
        "(New-Object System.Security.SecureString)"
    } else {
        "(ConvertTo-SecureString " + ps_q(pw) + " -AsPlainText -Force)"
    }
    let cred_prefix = if user != "" {
        "$cred = New-Object System.Management.Automation.PSCredential(" + ps_q(user) + ", " + secure + "); "
    } else { "" }
    ps_run(
        cred_prefix +
        "New-Service -Name " + ps_q(name) + " -BinaryPathName " + ps_q(path) + " -StartupType " + st +
        (if display != "" { " -DisplayName " + ps_q(display) } else { "" }) +
        (if desc != "" { " -Description " + ps_q(desc) } else { "" }) +
        (if user != "" { " -Credential $cred" } else { "" }) +
        " | Out-Null"
    )?
    Ok(ApplyResult::Success)
}
