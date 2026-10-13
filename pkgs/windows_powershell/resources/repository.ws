use value
use json
use common
use psget

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
// None when the repository is not registered, or when the edition is not
// installed yet; a query that fails is an error.
fn current_repository(params: Value, kind: string) -> Result[Option[Value], string] {
    let name = common::param_str(params, "name", "")
    let script = if kind == "psresourceget" {
        "Import-Module Microsoft.PowerShell.PSResourceGet\n$name = " + common::ps_q(name) + "\n@(Get-PSResourceRepository) | Where-Object {{ $_.Name -eq $name }} | Select-Object -First 1 @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.Uri}}}}, @{{n='trusted';e={{[bool]$_.Trusted}}}}, @{{n='priority';e={{[int]$_.Priority}}}}, @{{n='api_version';e={{[string]$_.ApiVersion}}}}, @{{n='publish_uri';e={{''}}}} | ConvertTo-Json -Compress"
    } else {
        "$name = " + common::ps_q(name) + "\n@(Get-PSRepository) | Where-Object {{ $_.Name -eq $name }} | Select-Object -First 1 @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.SourceLocation}}}}, @{{n='trusted';e={{$_.InstallationPolicy -eq 'Trusted'}}}}, @{{n='priority';e={{-1}}}}, @{{n='api_version';e={{''}}}}, @{{n='publish_uri';e={{[string]$_.PublishLocation}}}} | ConvertTo-Json -Compress"
    }
    if let Some(text) = common::query(common::param_str(params, "edition", "auto"), script)? {
        if text == "" { return Ok(None) }
        return Ok(Some(json::parse(text)?))
    }
    Ok(None)
}

fn field(v: Value, key: string) -> string {
    v.get(key).unwrap_or(Value::String("")).as_string().unwrap_or("")
}

fn wants_trusted(params: Value) -> Result[Option[bool], string] {
    let want = common::param_str(params, "trusted", "unmanaged")
    if want == "unmanaged" { return Ok(None) }
    if want == "yes" { return Ok(Some(true)) }
    if want == "no" { return Ok(Some(false)) }
    Err("invalid 'trusted' value '" + want + "' (expected :yes, :no or :unmanaged)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::require("name", name)?
    common::no_wildcards("name", name)?
    let kind = psget::provider(params)?
    let found = current_repository(params, kind)?
    if !common::want_present(params)? {
        if found.is_none() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if found.is_none() { return Ok(CheckResult::NotConfigured) }
    let current = found.unwrap()

    let uri = common::param_str(params, "uri", "")
    if uri != "" && norm_uri(field(current, "uri")) != norm_uri(uri) { return Ok(CheckResult::NotConfigured) }
    if let Some(trusted) = wants_trusted(params)? {
        if current.get("trusted").unwrap_or(Value::Bool(false)).as_bool().unwrap_or(false) != trusted {
            return Ok(CheckResult::NotConfigured)
        }
    }
    // Priority and the API version are PSResourceGet concepts; the publish
    // location is a PowerShellGet v2 one.
    if kind == "psresourceget" {
        let priority = common::param_int(params, "priority", -1)
        if priority >= 0 && current.get("priority").unwrap_or(Value::Int(-1)).as_int().unwrap_or(-1) != priority {
            return Ok(CheckResult::NotConfigured)
        }
        let api = common::param_str(params, "api_version", "unmanaged")
        if api != "unmanaged" && field(current, "api_version").to_lower() != common::pascal(api).to_lower() {
            return Ok(CheckResult::NotConfigured)
        }
    } else {
        let publish = common::param_str(params, "publish_uri", "")
        if publish != "" && norm_uri(field(current, "publish_uri")) != norm_uri(publish) { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn register_script(params: Value, kind: string, exists: bool) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    let uri = common::param_str(params, "uri", "")
    let priority = common::param_int(params, "priority", -1)
    let api = common::param_str(params, "api_version", "unmanaged")
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
            if uri != "" { args = args + " -Uri " + common::ps_q(uri) }
            if api != "unmanaged" { args = args + " -ApiVersion " + common::pascal(api) }
            if args == "" { return Ok(head + "Write-Output 'nothing to change'") }
            return Ok(head + "Set-PSResourceRepository -Name " + common::ps_q(name) + args)
        }
        // PSGallery is a named default rather than a feed the caller
        // describes, so it registers with no URI at all.
        if name == "PSGallery" { return Ok(head + "Register-PSResourceRepository -PSGallery" + args + " -Force") }
        if uri == "" { return Err("'uri' is required to register the repository '" + name + "'") }
        if api != "unmanaged" { args = args + " -ApiVersion " + common::pascal(api) }
        return Ok(head + "Register-PSResourceRepository -Name " + common::ps_q(name) + " -Uri " + common::ps_q(uri) + args + " -Force")
    }

    let policy = ""
    if let Some(t) = trusted {
        policy = if t { " -InstallationPolicy Trusted" } else { " -InstallationPolicy Untrusted" }
    }
    let publish = common::param_str(params, "publish_uri", "")
    let publish_arg = if publish == "" { "" } else { " -PublishLocation " + common::ps_q(publish) }
    if exists {
        let args = policy + publish_arg
        let location = if uri == "" { "" } else { " -SourceLocation " + common::ps_q(uri) }
        if args == "" && location == "" { return Ok("Write-Output 'nothing to change'") }
        return Ok("Set-PSRepository -Name " + common::ps_q(name) + location + args)
    }
    if name == "PSGallery" { return Ok("Register-PSRepository -Default -InstallationPolicy " + if trusted.unwrap_or(false) { "Trusted" } else { "Untrusted" }) }
    if uri == "" { return Err("'uri' is required to register the repository '" + name + "'") }
    Ok("Register-PSRepository -Name " + common::ps_q(name) + " -SourceLocation " + common::ps_q(uri) + policy + publish_arg)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    common::require("name", name)?
    common::no_wildcards("name", name)?
    let edition = common::param_str(params, "edition", "auto")
    if !common::ps_installed(edition) { return Err(common::not_installed(edition)) }
    let kind = psget::provider(params)?
    let exists = current_repository(params, kind)?.is_some()

    if !common::want_present(params)? {
        if !exists { return Ok(ApplyResult::Success) }
        let script = psget::import_line(kind) + if kind == "psresourceget" { "Unregister-PSResourceRepository -Name " } else { "Unregister-PSRepository -Name " } + common::ps_q(name)
        let out = common::run_ps(edition, script)?
        if !out.success { return Err(common::failure("unregistering '" + name + "'", out)) }
        return Ok(ApplyResult::Success)
    }

    let out = common::run_ps(edition, register_script(params, kind, exists)?)?
    if !out.success { return Err(common::failure("registering '" + name + "'", out)) }
    Ok(ApplyResult::Success)
}
