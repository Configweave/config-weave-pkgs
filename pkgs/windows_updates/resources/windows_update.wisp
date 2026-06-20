use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// Number of applicable, not-yet-installed updates matching `query`, via the
// built-in Windows Update Agent COM API (no PSWindowsUpdate dependency).
fn pending(query: string) -> Result[int, string] {
    let script = "$ErrorActionPreference='Stop'; $s = New-Object -ComObject Microsoft.Update.Session; $r = $s.CreateUpdateSearcher().Search(" + ps_q(query) + "); $r.Updates.Count"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim().parse_int().unwrap_or(0))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let query = param_str(params, "query", "IsInstalled=0 and IsHidden=0")
    if pending(query)? == 0 { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let query = param_str(params, "query", "IsInstalled=0 and IsHidden=0")
    let script = "$ErrorActionPreference='Stop'; " +
        "$s = New-Object -ComObject Microsoft.Update.Session; " +
        "$r = $s.CreateUpdateSearcher().Search(" + ps_q(query) + "); " +
        "if ($r.Updates.Count -eq 0) { exit 0 }; " +
        "$dl = $s.CreateUpdateDownloader(); $dl.Updates = $r.Updates; $dl.Download() | Out-Null; " +
        "$inst = $s.CreateUpdateInstaller(); $inst.Updates = $r.Updates; $ir = $inst.Install(); " +
        "if ($ir.RebootRequired) { exit 3010 } elseif ($ir.ResultCode -eq 2) { exit 0 } else { exit 1 }"
    let out = shell::powershell(script, Value::Null)?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err("windows update install failed: " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
