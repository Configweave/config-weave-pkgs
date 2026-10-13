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

// Read through Microsoft.Web.Administration's ServerManager rather than
// Get-Website plus an XPath per site: no site name is ever spliced into a
// filter, and each site is read inside its own try, so one site that cannot
// be read (a name IIS's XPath cannot express, a W3SVC that is not running)
// costs its state, not the whole gather.
//
// ssl_flags is spelled the way windows_iis.binding's ssl_flags symbol is —
// none, sni, central_cert_store or sni_central_cert_store — so a gathered
// binding can be fed straight back into a binding step.
fn gather(params: Value) -> Result[Value, string] {
    let raw = ps_out(
        "$sites = @(); " +
        "try {{ Add-Type -Path (Join-Path $env:windir 'system32\\inetsrv\\Microsoft.Web.Administration.dll'); " +
        "$sites = @((New-Object Microsoft.Web.Administration.ServerManager).Sites) }} catch {{ }}; " +
        "$names = @('none', 'sni', 'central_cert_store', 'sni_central_cert_store'); " +
        "$out = @($sites | ForEach-Object {{ $s = $_; " +
        "$state = ''; try {{ $state = [string]$s.State }} catch {{ }}; " +
        "$pool = ''; $phys = ''; try {{ $app = $s.Applications['/']; $pool = [string]$app.ApplicationPoolName; " +
        "$phys = [string]$app.VirtualDirectories['/'].PhysicalPath }} catch {{ }}; " +
        "[pscustomobject]@{{ name = [string]$s.Name; id = [int64]$s.Id; " +
        "state = $state; physical_path = $phys; app_pool = $pool; " +
        "bindings = @($s.Bindings | ForEach-Object {{ " +
        "$h = $_.CertificateHash; $hex = ''; " +
        "if ($h -is [byte[]]) {{ $hex = (($h | ForEach-Object {{ $_.ToString('X2') }}) -join '') }} " +
        "elseif ($null -ne $h) {{ $hex = [string]$h }}; " +
        "$fl = 0; try {{ $fl = ([int]$_.SslFlags) -band 3 }} catch {{ }}; " +
        "[pscustomobject]@{{ protocol = [string]$_.Protocol; " +
        "binding_information = [string]$_.BindingInformation; " +
        "ssl_flags = $names[$fl]; certificate_hash = $hex }} }}) }} }}); " +
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
