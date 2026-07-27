use value
use shell
use json
use registry

// Whether IIS is here at all, and how much of it there is. Every field has to
// be answerable on a machine with no IIS — a gatherer that errored there would
// make `installed` impossible to branch on, which is the main thing a playbook
// wants it for.

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

// The InetStp key is written by the IIS role installer, so its MajorVersion is
// the version of IIS rather than of Windows.
fn version() -> Result[string, string] {
    let key = "HKLM\\SOFTWARE\\Microsoft\\InetStp"
    if !registry::key_exists(key)? { return Ok("") }
    let major = 0
    if let Some(v) = registry::read(key, "MajorVersion")? {
        if let Some(i) = v.as_int() { major = i }
    }
    let minor = 0
    if let Some(v) = registry::read(key, "MinorVersion")? {
        if let Some(i) = v.as_int() { minor = i }
    }
    if major == 0 { return Ok("") }
    Ok(json::to_string(Value::Int(major)) + "." + json::to_string(Value::Int(minor)))
}

fn gather(params: Value) -> Result[Value, string] {
    let ver = version()?
    if ver == "" {
        return Ok(Value::Map(#{
            "installed": Value::Bool(false),
            "version": Value::String(""),
            "rewrite_installed": Value::Bool(false),
            "site_count": Value::Int(0),
            "app_pool_count": Value::Int(0),
        }))
    }
    // One round trip for the counts and the rewrite probe. WebAdministration
    // may still be missing even with the role installed — the scripting tools
    // are their own role service — so the counts fall back to zero rather than
    // failing the gather.
    let raw = ps_out(
        "$sites = 0; $pools = 0; " +
        "try {{ Import-Module WebAdministration; " +
        "$sites = @(Get-Website).Count; $pools = @(Get-ChildItem IIS:\\AppPools).Count }} catch {{ }}; " +
        "$rw = Test-Path (Join-Path $env:windir 'system32\\inetsrv\\rewrite.dll'); " +
        "[pscustomobject]@{{ sites = $sites; pools = $pools; rewrite = [bool]$rw }} | " +
        "ConvertTo-Json -Compress")?
    let info = json::parse(raw)?
    let sites = 0
    if let Some(v) = info.get("sites") { if let Some(i) = v.as_int() { sites = i } }
    let pools = 0
    if let Some(v) = info.get("pools") { if let Some(i) = v.as_int() { pools = i } }
    let rewrite = false
    if let Some(v) = info.get("rewrite") { if let Some(b) = v.as_bool() { rewrite = b } }
    Ok(Value::Map(#{
        "installed": Value::Bool(true),
        "version": Value::String(ver),
        "rewrite_installed": Value::Bool(rewrite),
        "site_count": Value::Int(sites),
        "app_pool_count": Value::Int(pools),
    }))
}
