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
fn run_ps(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    let out = shell::run(dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file), Value::Map(#{ "timeout": Value::Int(300) }))
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

// PowerShell has two generations of these cmdlets. :auto prefers the newer
// one, which PowerShell 7.4+ ships in the box, and falls back to the v2
// module a stock Windows Server has.
fn provider(params: Value) -> Result[string, string] {
    let requested = param_str(params, "provider", "auto")
    if requested == "psresourceget" { return Ok("psresourceget") }
    if requested == "powershellget" { return Ok("powershellget") }
    if requested != "auto" { return Err("invalid 'provider' value '" + requested + "'") }
    let edition = param_str(params, "edition", "auto")
    // Probing the cmdlet rather than listing the module: PSResourceGet ships
    // inside PowerShell 7 and stays usable even when PSModulePath has been
    // overridden so that Get-Module -ListAvailable no longer finds it. Getting
    // this wrong falls back to the v2 cmdlets, which under pwsh on Windows go
    // through the Windows PowerShell compatibility layer and can block.
    let probe = "if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {{ Write-Output 'psresourceget' }} else {{ Write-Output 'powershellget' }}"
    // A probe that cannot run at all means the target PowerShell is not
    // installed yet — run 1 checks every step before the install step has
    // applied — so fall back to the edition's usual generation.
    let out = run_ps(edition, probe)
    if let Ok(result) = out {
        if result.success {
            let detected = result.stdout.trim()
            if detected != "" { return Ok(detected) }
        }
    }
    if resolved_edition(edition) == "windows_powershell" { return Ok("powershellget") }
    Ok("psresourceget")
}

// A file-based repository comes back as a file:// URL, so the configured
// value and the reported one have to be compared in the same shape.
fn norm_uri(raw: string) -> string {
    let s = raw.trim()
    if s.starts_with("file://") { s = s.slice(7, s.len()) }
    s = s.replace("\\", "/")
    // file:///C:/x leaves a stray leading slash before the drive letter.
    if s.len() > 2 && s.slice(0, 1) == "/" && s.slice(2, 3) == ":" { s = s.slice(1, s.len()) }
    while s.len() > 1 && s.ends_with("/") { s = s.slice(0, s.len() - 1) }
    s
}

// Projected to plain scalars in PowerShell rather than serialising the whole
// object: Uri is a System.Uri and would otherwise arrive as a nested map.
fn current_repository(params: Value, kind: string) -> Result[Value, string] {
    let name = param_str(params, "name", "")
    let script = if kind == "psresourceget" {
        "Import-Module Microsoft.PowerShell.PSResourceGet\nGet-PSResourceRepository -Name " + ps_q(name) + " -ErrorAction SilentlyContinue | Select-Object -First 1 @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.Uri}}}}, @{{n='trusted';e={{[bool]$_.Trusted}}}}, @{{n='priority';e={{[int]$_.Priority}}}} | ConvertTo-Json -Compress"
    } else {
        "Get-PSRepository -Name " + ps_q(name) + " -ErrorAction SilentlyContinue | Select-Object -First 1 @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.SourceLocation}}}}, @{{n='trusted';e={{$_.InstallationPolicy -eq 'Trusted'}}}}, @{{n='priority';e={{-1}}}} | ConvertTo-Json -Compress"
    }
    // A query that cannot run at all — no PowerShell of that edition, or a
    // PowerShellGet too old to answer — means "no such repository", not a
    // failure: run 1 checks every step before any of them has applied.
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

fn wants_trusted(params: Value) -> Result[Option[bool], string] {
    let want = param_str(params, "trusted", "unmanaged")
    if want == "unmanaged" { return Ok(None) }
    if want == "yes" { return Ok(Some(true)) }
    if want == "no" { return Ok(Some(false)) }
    Err("invalid 'trusted' value '" + want + "' (expected :yes, :no or :unmanaged)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let kind = provider(params)?
    let current = current_repository(params, kind)?
    if !want_present(params)? {
        if current.is_null() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if current.is_null() { return Ok(CheckResult::NotConfigured) }

    let uri = param_str(params, "uri", "")
    if uri != "" {
        let reported = current.get("uri").unwrap_or(Value::String("")).as_string().unwrap_or("")
        if norm_uri(reported) != norm_uri(uri) { return Ok(CheckResult::NotConfigured) }
    }
    if let Some(trusted) = wants_trusted(params)? {
        if current.get("trusted").unwrap_or(Value::Bool(false)).as_bool().unwrap_or(false) != trusted {
            return Ok(CheckResult::NotConfigured)
        }
    }
    // Priority is a PSResourceGet concept; the v2 projection reports -1 and
    // so never disagrees.
    let priority = param_int(params, "priority", -1)
    if priority >= 0 && kind == "psresourceget" {
        if current.get("priority").unwrap_or(Value::Int(-1)).as_int().unwrap_or(-1) != priority {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn register_script(params: Value, kind: string, exists: bool) -> Result[string, string] {
    let name = param_str(params, "name", "")
    let uri = param_str(params, "uri", "")
    let priority = param_int(params, "priority", -1)
    let api = param_str(params, "api_version", "unmanaged")
    let trusted = wants_trusted(params)?

    if kind == "psresourceget" {
        let head = "Import-Module Microsoft.PowerShell.PSResourceGet\n"
        let args = ""
        if let Some(t) = trusted {
            if t { args = args + " -Trusted" } else { args = args + " -Trusted:$false" }
        }
        if priority >= 0 { args = args + " -Priority " + str(priority) }
        if exists {
            // Set-PSResourceRepository refuses an empty -Uri, so it is only
            // passed when the caller actually gave one.
            if uri != "" { args = args + " -Uri " + ps_q(uri) }
            if api != "unmanaged" { args = args + " -ApiVersion " + pascal(api) }
            if args == "" { return Ok(head + "Write-Output 'nothing to change'") }
            return Ok(head + "Set-PSResourceRepository -Name " + ps_q(name) + args)
        }
        // PSGallery is a named default rather than a feed the caller
        // describes, so it registers with no URI at all.
        if name == "PSGallery" { return Ok(head + "Register-PSResourceRepository -PSGallery" + args + " -Force") }
        if uri == "" { return Err("'uri' is required to register the repository '" + name + "'") }
        if api != "unmanaged" { args = args + " -ApiVersion " + pascal(api) }
        return Ok(head + "Register-PSResourceRepository -Name " + ps_q(name) + " -Uri " + ps_q(uri) + args + " -Force")
    }

    let policy = ""
    if let Some(t) = trusted {
        policy = if t { " -InstallationPolicy Trusted" } else { " -InstallationPolicy Untrusted" }
    }
    let publish = param_str(params, "publish_uri", "")
    let publish_arg = if publish == "" { "" } else { " -PublishLocation " + ps_q(publish) }
    if exists {
        let args = policy + publish_arg
        let location = if uri == "" { "" } else { " -SourceLocation " + ps_q(uri) }
        if args == "" && location == "" { return Ok("Write-Output 'nothing to change'") }
        return Ok("Set-PSRepository -Name " + ps_q(name) + location + args)
    }
    if name == "PSGallery" { return Ok("Register-PSRepository -Default -InstallationPolicy " + if trusted.unwrap_or(false) { "Trusted" } else { "Untrusted" }) }
    if uri == "" { return Err("'uri' is required to register the repository '" + name + "'") }
    Ok("Register-PSRepository -Name " + ps_q(name) + " -SourceLocation " + ps_q(uri) + policy + publish_arg)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let edition = param_str(params, "edition", "auto")
    let kind = provider(params)?
    let exists = !current_repository(params, kind)?.is_null()

    if !want_present(params)? {
        if !exists { return Ok(ApplyResult::Success) }
        let script = if kind == "psresourceget" {
            "Import-Module Microsoft.PowerShell.PSResourceGet\nUnregister-PSResourceRepository -Name " + ps_q(name)
        } else {
            "Unregister-PSRepository -Name " + ps_q(name)
        }
        let out = run_ps(edition, script)?
        if !out.success { return Err("unregistering '" + name + "' failed: " + out.stderr.trim()) }
        return Ok(ApplyResult::Success)
    }

    let out = run_ps(edition, register_script(params, kind, exists)?)?
    if !out.success { return Err("registering '" + name + "' failed: " + out.stderr.trim() + " " + out.stdout.trim()) }
    Ok(ApplyResult::Success)
}
