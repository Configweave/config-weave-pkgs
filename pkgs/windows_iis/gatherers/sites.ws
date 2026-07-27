use value
use shell
use json

// Every configured site with its state, root path, pool and bindings.
//
// An empty list on a machine without IIS rather than an error: a playbook that
// gathers this to decide whether to converge a site should not fail before it
// gets the chance.

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

// ConvertTo-Json in Windows PowerShell 5.1 collapses a one-element array to
// the object itself, so a single site or a single binding has to be accepted
// in both shapes.
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

fn get_int(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(i) = v.as_int() { return i } }
    0
}

fn bindings_of(site: Value) -> Value {
    let out: List[Value] = []
    if let Some(bs) = site.get("bindings") {
        for b in as_items(bs) {
            out.push(Value::Map(#{
                "protocol": Value::String(get_str(b, "protocol")),
                "binding_information": Value::String(get_str(b, "binding_information")),
                "ssl_flags": Value::String(get_str(b, "ssl_flags")),
                "certificate_hash": Value::String(get_str(b, "certificate_hash")),
            }))
        }
    }
    Value::List(out)
}

fn gather(params: Value) -> Result[Value, string] {
    let raw = ps_out(
        "$sites = @(); " +
        "try {{ Import-Module WebAdministration; $sites = @(Get-Website) }} catch {{ }}; " +
        "$out = @($sites | ForEach-Object {{ $s = $_; " +
        "$app = Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' " +
        "-Filter \"system.applicationHost/sites/site[@name='$($s.name)']/application[@path='/']\"; " +
        "[pscustomobject]@{{ name = [string]$s.name; id = [int]$s.id; " +
        "state = [string]$s.state; physical_path = [string]$s.physicalPath; " +
        "app_pool = [string]$app.applicationPool; " +
        "bindings = @($s.bindings.Collection | ForEach-Object {{ " +
        "$h = $_.certificateHash; $hex = ''; " +
        "if ($h -is [byte[]]) {{ $hex = (($h | ForEach-Object {{ $_.ToString('X2') }}) -join '') }} " +
        "elseif ($null -ne $h) {{ $hex = [string]$h }}; " +
        "[pscustomobject]@{{ protocol = [string]$_.protocol; " +
        "binding_information = [string]$_.bindingInformation; " +
        "ssl_flags = [string]$_.sslFlags; certificate_hash = $hex }} }}) }} }}); " +
        "ConvertTo-Json -InputObject @($out) -Compress -Depth 5")?
    let sites: List[Value] = []
    if raw != "" && raw != "null" {
        for s in as_items(json::parse(raw)?) {
            sites.push(Value::Map(#{
                "name": Value::String(get_str(s, "name")),
                "id": Value::Int(get_int(s, "id")),
                "state": Value::String(get_str(s, "state")),
                "physical_path": Value::String(get_str(s, "physical_path")),
                "app_pool": Value::String(get_str(s, "app_pool")),
                "bindings": bindings_of(s),
            }))
        }
    }
    Ok(Value::Map(#{ "sites": Value::List(sites) }))
}
