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

// :unmanaged means "do not look at this aspect" — it is what lets one
// resource register a service without also deciding whether it runs.
fn desired_state(params: Value) -> Result[string, string] {
    let s = param_str(params, "state", "unmanaged")
    if s == "running" || s == "stopped" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'state' value '" + s + "' (expected :running, :stopped or :unmanaged)")
}

fn desired_startup(params: Value) -> Result[string, string] {
    let s = param_str(params, "startup", "unmanaged")
    if s == "automatic" || s == "manual" || s == "disabled" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'startup' value '" + s + "' (expected :automatic, :manual, :disabled or :unmanaged)")
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

// New-Service wants the PascalCase spelling; the `service` host module
// speaks the same lowercase tokens as the params.
fn ps_startup_type(startup: string) -> string {
    if startup == "manual" { return "Manual" }
    if startup == "disabled" { return "Disabled" }
    "Automatic"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let exists = installed(name)?
    if !want_present(params)? {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // `path` is only needed to create the service; managing an existing one
    // (startup, state) does not require knowing its binary.
    if !exists {
        if param_str(params, "path", "") == "" {
            return Err("service '" + name + "' does not exist and no 'path' was given to create it")
        }
        return Ok(CheckResult::NotConfigured)
    }
    // path/display_name/description/user are create-only: an existing
    // registration is not rewritten. startup and state, unlike before, are
    // reconciled on every run rather than only set at creation.
    let su = desired_startup(params)?
    if su != "unmanaged" && service::startup(name)? != su { return Ok(CheckResult::NotConfigured) }
    let st = desired_state(params)?
    // Transitional states (start_pending, stop_pending, paused, ...) count as
    // not yet configured; apply nudges them to the target.
    if st != "unmanaged" && service::status(name)? != st { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
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
    let su = desired_startup(params)?
    if !installed(name)? {
        let path = param_str(params, "path", "")
        if path == "" {
            return Err("service '" + name + "' does not exist and no 'path' was given to create it")
        }
        // New-Service requires a startup type, so :unmanaged creates the
        // service Automatic and then leaves it alone.
        let create_type = ps_startup_type(if su == "unmanaged" { "automatic" } else { su })
        let display = param_str(params, "display_name", "")
        let desc = param_str(params, "description", "")
        let user = param_str(params, "user", "")
        let pw = param_str(params, "password", "")
        // Built-in accounts have no password; PSCredential still needs a
        // (then empty) SecureString.
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
            "New-Service -Name " + ps_q(name) + " -BinaryPathName " + ps_q(path) + " -StartupType " + create_type +
            (if display != "" { " -DisplayName " + ps_q(display) } else { "" }) +
            (if desc != "" { " -Description " + ps_q(desc) } else { "" }) +
            (if user != "" { " -Credential $cred" } else { "" }) +
            " | Out-Null"
        )?
    }
    if su != "unmanaged" && service::startup(name)? != su { service::set_startup(name, su)? }
    let st = desired_state(params)?
    if st != "unmanaged" && service::status(name)? != st {
        if st == "running" { service::start(name)? } else { service::stop(name)? }
    }
    Ok(ApplyResult::Success)
}
