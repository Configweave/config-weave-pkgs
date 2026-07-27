use value
use shell
use json

// Every application pool with its runtime, pipeline mode, identity and state.
//
// An empty list on a machine without IIS rather than an error, for the same
// reason as the sites gatherer.

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

// ConvertTo-Json in Windows PowerShell 5.1 collapses a one-element array to
// the object itself, so a single pool has to be accepted in both shapes.
fn as_items(v: Value) -> List[Value] {
    let out: List[Value] = []
    if let Some(items) = v.as_list() {
        for item in items { out.push(item) }
    } else if let Some(single) = v.as_map() {
        out.push(Value::Map(single))
    }
    out
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

fn gather(params: Value) -> Result[Value, string] {
    let raw = ps_out(
        "$pools = @(); " +
        "try {{ Import-Module WebAdministration; $pools = @(Get-ChildItem IIS:\\AppPools) }} " +
        "catch {{ }}; " +
        "$out = @($pools | ForEach-Object {{ " +
        "[pscustomobject]@{{ name = [string]$_.name; " +
        "state = [string]$_.state; " +
        "managed_runtime_version = [string]$_.managedRuntimeVersion; " +
        "managed_pipeline_mode = [string]$_.managedPipelineMode; " +
        "identity_type = [string]$_.processModel.identityType; " +
        "enable_32bit = [bool]$_.enable32BitAppOnWin64 }} }}); " +
        "ConvertTo-Json -InputObject @($out) -Compress -Depth 4")?
    let pools: List[Value] = []
    if raw != "" && raw != "null" {
        for p in as_items(json::parse(raw)?) {
            pools.push(Value::Map(#{
                "name": Value::String(get_str(p, "name")),
                "state": Value::String(get_str(p, "state")),
                "managed_runtime_version": Value::String(get_str(p, "managed_runtime_version")),
                "managed_pipeline_mode": Value::String(get_str(p, "managed_pipeline_mode")),
                "identity_type": Value::String(get_str(p, "identity_type")),
                "enable_32bit": Value::Bool(get_bool(p, "enable_32bit")),
            }))
        }
    }
    Ok(Value::Map(#{ "app_pools": Value::List(pools) }))
}
