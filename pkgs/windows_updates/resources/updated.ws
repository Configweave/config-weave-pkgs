use value
use fs
use path
use shell
use time

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// The stamp's mtime records the last run that left the host fully drained.
// It is only an optimisation: it lets `check` skip a Windows Update Agent
// search, which is slow and network-bound.
fn stamp_path() -> string { "C:/ProgramData/config-weave/windows-updated" }

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
}

fn last_run() -> Result[int, string] {
    let meta = fs::metadata(stamp_path())?
    // `modified` is always present (0 where the platform can't report it),
    // and an epoch mtime simply forces a search.
    if let Some(m) = meta.get("modified") {
        if let Some(ts) = m.as_int() { return Ok(ts) }
    }
    Ok(0)
}

fn within_window(params: Value) -> Result[bool, string] {
    if !fs::is_file(stamp_path()) { return Ok(false) }
    Ok(time::now_millis() / 1000 - last_run()? <= max_age_secs(params))
}

fn stamp() -> Result[unit, string] {
    let p = stamp_path()
    fs::mkdir(path::parent(p))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(p, "windows-update\n")?
    Ok(())
}

// Applicable, not-yet-installed updates matching `query`, via the built-in
// Windows Update Agent COM API (no PSWindowsUpdate dependency).
fn pending(query: string) -> Result[int, string] {
    let script = "$ErrorActionPreference='Stop'; $s = New-Object -ComObject Microsoft.Update.Session; $r = $s.CreateUpdateSearcher().Search(" + ps_q(query) + "); $r.Updates.Count"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim().parse_int().unwrap_or(0))
}

fn check(params: Value) -> Result[CheckResult, string] {
    // A fresh stamp means the last run drained the host, so the expensive
    // search is skipped until the window lapses.
    if within_window(params)? { return Ok(CheckResult::AlreadyConfigured) }
    if pending(param_str(params, "query", "IsInstalled=0 and IsHidden=0"))? == 0 {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let query = param_str(params, "query", "IsInstalled=0 and IsHidden=0")
    if pending(query)? == 0 {
        stamp()?
        return Ok(ApplyResult::Success)
    }
    let script = "$ErrorActionPreference='Stop'; " +
        "$s = New-Object -ComObject Microsoft.Update.Session; " +
        "$r = $s.CreateUpdateSearcher().Search(" + ps_q(query) + "); " +
        "if ($r.Updates.Count -eq 0) {{ exit 0 }}; " +
        "$dl = $s.CreateUpdateDownloader(); $dl.Updates = $r.Updates; $dl.Download() | Out-Null; " +
        "$inst = $s.CreateUpdateInstaller(); $inst.Updates = $r.Updates; $ir = $inst.Install(); " +
        "if ($ir.RebootRequired) {{ exit 3010 }} elseif ($ir.ResultCode -eq 2) {{ exit 0 }} else {{ exit 1 }}"
    let out = shell::powershell(script, Value::Null)?
    if out.code == 3010 {
        // Deliberately no stamp: the host is not drained, and more updates
        // usually only become applicable after the reboot. Leaving the
        // window stale is what lets a playbook loop — reboot, re-check,
        // install the next wave — until a pass finds nothing pending.
        return Ok(ApplyResult::RebootRequired)
    }
    if !out.success { return Err("windows update install failed: " + out.stderr.trim()) }
    // Installed without needing a reboot; only claim the window if this pass
    // actually left nothing behind.
    if pending(query)? == 0 { stamp()? }
    Ok(ApplyResult::Success)
}
