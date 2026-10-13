use value
use fs
use path
use log
use hash
use registry
use shell
use time
use common

fn default_query() -> string { "IsInstalled=0 and IsHidden=0 and Type='Software'" }

// The Microsoft Update service, which adds other Microsoft products to the
// Windows Update catalog. It has to be registered before it can be searched.
fn microsoft_update_id() -> string { "7971f918-a847-4430-9279-4a52d1efe18d" }

fn work_dir() -> string { "C:\\ProgramData\\config-weave\\windows-updates" }

fn task_name() -> string { "config-weave-windows-updates" }

fn query(params: Value) -> string { common::param_str(params, "query", default_query()) }

fn source(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "source", "default")
    if s == "default" || s == "windows_update" || s == "microsoft_update" { return Ok(s) }
    Err("invalid 'source' value '" + s + "' (expected :default, :windows_update or :microsoft_update)")
}

// The stamp's mtime records the last run that left the host fully drained
// for this query and source. It is only an optimisation: it lets `check`
// skip a Windows Update Agent search, which is slow and network-bound.
// Changing the query or source names a different stamp, so it searches.
fn stamp_path(params: Value) -> Result[string, string] {
    let id = hash::sha256(source(params)? + "\n" + query(params)).slice(0, 16)
    Ok("C:/ProgramData/config-weave/windows-updated-" + id)
}

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    common::param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
}

fn within_window(params: Value) -> Result[bool, string] {
    let p = stamp_path(params)?
    if !fs::is_file(p) { return Ok(false) }
    let meta = fs::metadata(p)?
    // `modified` is always present (0 where the platform can't report it),
    // and an epoch mtime simply forces a search.
    let modified = 0
    if let Some(m) = meta.get("modified") { if let Some(ts) = m.as_int() { modified = ts } }
    Ok(time::now_millis() / 1000 - modified <= max_age_secs(params))
}

fn stamp(params: Value) -> Result[unit, string] {
    let p = stamp_path(params)?
    fs::mkdir(path::parent(p))?
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(p, "windows-update\n")?
    Ok(())
}

// Windows Update sets this key while an installed update waits for a
// restart. It is read from the registry rather than through
// Microsoft.Update.SystemInfo, which WUA refuses to network logon sessions.
fn reboot_pending() -> Result[bool, string] {
    registry::key_exists("HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired")
}

// PowerShell that leaves `$session` and `$updates`: the applicable updates
// matching the query on the chosen source, minus any that would stop to ask
// a user something, which an unattended install can never answer.
fn search_ps(params: Value) -> Result[string, string] {
    let src = source(params)?
    let select = if src == "windows_update" {
        "$searcher.ServerSelection = 2; "
    } else if src == "microsoft_update" {
        "$searcher.ServerSelection = 3; $searcher.ServiceID = " + common::ps_q(microsoft_update_id()) + "; "
    } else { "" }
    Ok("$session = New-Object -ComObject Microsoft.Update.Session; " +
        "$searcher = $session.CreateUpdateSearcher(); " + select +
        "$found = @($searcher.Search(" + common::ps_q(query(params)) + ").Updates); " +
        "$updates = @($found | Where-Object {{ -not $_.InstallationBehavior.CanRequestUserInput }}); ")
}

fn mu_registered_ps() -> string {
    "@((New-Object -ComObject Microsoft.Update.ServiceManager).Services | Where-Object {{ $_.ServiceID -eq " +
        common::ps_q(microsoft_update_id()) + " }}).Count -gt 0"
}

// The number of pending updates, or -1 when the Microsoft Update service the
// search needs is not registered yet (apply registers it).
fn pending(params: Value) -> Result[int, string] {
    let guard = if source(params)? == "microsoft_update" {
        "if (-not (" + mu_registered_ps() + ")) {{ '-1'; exit 0 }}; "
    } else { "" }
    let out = common::powershell("windows update search",
        "$ErrorActionPreference='Stop'; " + guard + search_ps(params)? + "$updates.Count")?
    let lines = out.split("\n")
    if let Some(n) = lines[lines.len() - 1].trim().parse_int() { return Ok(n) }
    Err("windows update search printed no count: " + out)
}

// The install script the scheduled task runs. It loops search, download,
// install until nothing is pending, a reboot is needed, a pass installs
// nothing, or five passes have run — later updates often only become
// applicable once earlier ones are in. Every line goes to install.log, and
// the exit code to install.done, which is what the caller waits for.
//   0 drained, 3010 reboot required, 2 updates still pending, 1 error.
fn install_script(params: Value) -> Result[string, string] {
    let dir = work_dir()
    let register = if source(params)? == "microsoft_update" {
        "  if (-not (" + mu_registered_ps() + ")) {{\n" +
        "    (New-Object -ComObject Microsoft.Update.ServiceManager).AddService2(" + common::ps_q(microsoft_update_id()) + ", 7, '') | Out-Null\n" +
        "    Say 'registered the Microsoft Update service'\n" +
        "  }}\n"
    } else { "" }
    Ok("\u{FEFF}$ErrorActionPreference = 'Stop'\n" +
        "$log = " + common::ps_q(dir + "\\install.log") + "\n" +
        "$done = " + common::ps_q(dir + "\\install.done") + "\n" +
        "function Say($m) {{ Add-Content -LiteralPath $log -Value $m -Encoding UTF8 }}\n" +
        "function Hex($h) {{ '0x' + ([int64]$h -band 0xFFFFFFFF).ToString('X8') }}\n" +
        "$code = 1\n" +
        "try {{\n" + register +
        "  for ($pass = 1; $pass -le 5; $pass++) {{\n" +
        "    " + search_ps(params)? + "\n" +
        "    $skipped = $found.Count - $updates.Count\n" +
        "    if ($skipped -gt 0) {{ Say ('skipped ' + $skipped + ' update(s) that request user input') }}\n" +
        "    if ($updates.Count -eq 0) {{ $code = 0; break }}\n" +
        "    $code = 2\n" +
        "    Say ('pass ' + $pass + ': ' + $updates.Count + ' update(s) pending')\n" +
        "    $coll = New-Object -ComObject Microsoft.Update.UpdateColl\n" +
        "    foreach ($u in $updates) {{ if (-not $u.EulaAccepted) {{ $u.AcceptEula() }}; [void]$coll.Add($u) }}\n" +
        "    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; $dr = $dl.Download()\n" +
        "    Say ('download: ResultCode ' + $dr.ResultCode + ' HResult ' + (Hex $dr.HResult))\n" +
        "    $ready = New-Object -ComObject Microsoft.Update.UpdateColl\n" +
        "    for ($i = 0; $i -lt $coll.Count; $i++) {{\n" +
        "      $u = $coll.Item($i)\n" +
        "      if ($u.IsDownloaded) {{ [void]$ready.Add($u) }} else {{ $r = $dr.GetUpdateResult($i); Say ('not downloaded: ' + $u.Title + ' ResultCode ' + $r.ResultCode + ' HResult ' + (Hex $r.HResult)) }}\n" +
        "    }}\n" +
        "    if ($ready.Count -eq 0) {{ throw ('no update downloaded (download ResultCode ' + $dr.ResultCode + ', HResult ' + (Hex $dr.HResult) + ')') }}\n" +
        "    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $ready; $ir = $inst.Install()\n" +
        "    $installed = 0\n" +
        "    for ($i = 0; $i -lt $ready.Count; $i++) {{\n" +
        "      $r = $ir.GetUpdateResult($i)\n" +
        "      Say ('installed: ' + $ready.Item($i).Title + ' ResultCode ' + $r.ResultCode + ' HResult ' + (Hex $r.HResult))\n" +
        "      if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) {{ $installed++ }}\n" +
        "    }}\n" +
        "    Say ('install: ResultCode ' + $ir.ResultCode + ' HResult ' + (Hex $ir.HResult) + ' RebootRequired ' + $ir.RebootRequired)\n" +
        "    if ($ir.RebootRequired) {{ $code = 3010; break }}\n" +
        "    if ($installed -eq 0) {{ break }}\n" +
        "  }}\n" +
        "}} catch {{\n" +
        "  Say ('error: ' + $_.Exception.Message)\n" +
        "  $code = 1\n" +
        "}} finally {{\n" +
        "  Set-Content -LiteralPath $done -Value $code\n" +
        "}}\n" +
        "exit $code\n")
}

// WUA refuses downloads and installs to network logon sessions (SSH, WinRM)
// with E_ACCESSDENIED, so the install runs as SYSTEM in a one-shot scheduled
// task, and this waits for the result file the task writes. There is no
// timeout: a large update wave can run for hours.
fn run_task() -> Result[CmdOutput, string] {
    let dir = work_dir()
    let script = "$ErrorActionPreference = 'Stop'\n" +
        "$dir = " + common::ps_q(dir) + "\n" +
        "$name = " + common::ps_q(task_name()) + "\n" +
        "$done = Join-Path $dir 'install.done'; $log = Join-Path $dir 'install.log'\n" +
        "Remove-Item -LiteralPath $done, $log -Force -ErrorAction SilentlyContinue\n" +
        "$arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"' + (Join-Path $dir 'install.ps1') + '\"'\n" +
        "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg\n" +
        "$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest\n" +
        "$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries\n" +
        "Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null\n" +
        "$code = 1\n" +
        "try {{\n" +
        "  Start-ScheduledTask -TaskName $name\n" +
        "  $idle = 0\n" +
        "  while (-not (Test-Path -LiteralPath $done)) {{\n" +
        "    Start-Sleep -Seconds 5\n" +
        "    $state = (Get-ScheduledTask -TaskName $name).State\n" +
        "    if ($state -eq 'Running' -or $state -eq 'Queued') {{ $idle = 0; continue }}\n" +
        "    $idle++\n" +
        "    if ($idle -ge 6 -and -not (Test-Path -LiteralPath $done)) {{\n" +
        "      $last = (Get-ScheduledTaskInfo -TaskName $name).LastTaskResult\n" +
        "      throw ('the update task stopped without a result (state ' + $state + ', LastTaskResult ' + $last + ')')\n" +
        "    }}\n" +
        "  }}\n" +
        "  $code = [int](Get-Content -LiteralPath $done -Raw).Trim()\n" +
        "  if (Test-Path -LiteralPath $log) {{ Get-Content -LiteralPath $log -Encoding UTF8 }}\n" +
        "}} finally {{\n" +
        "  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue\n" +
        "}}\n" +
        "exit $code\n"
    shell::powershell(script, Value::Null)
}

fn check(params: Value) -> Result[CheckResult, string] {
    // An install waiting on a restart is not drained, whatever the stamp says.
    if reboot_pending()? { return Ok(CheckResult::RebootRequired) }
    // A fresh stamp means the last run drained the host, so the expensive
    // search is skipped until the window lapses.
    if within_window(params)? { return Ok(CheckResult::AlreadyConfigured) }
    if pending(params)? == 0 { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    fs::mkdir(work_dir())?
    fs::write(path::join(work_dir(), "install.ps1"), install_script(params)?)?
    let out = run_task()?
    for line in out.stdout.trim().split("\n") {
        if line.trim() != "" { log::info(line.trim()) }
    }
    if out.code == 3010 {
        // Deliberately no stamp: the host is not drained, and more updates
        // usually only become applicable after the reboot. Leaving the
        // window stale is what lets a playbook loop — reboot, re-check,
        // install the next wave — until a pass finds nothing pending.
        return Ok(ApplyResult::RebootRequired)
    }
    if out.code == 2 {
        return Err("windows updates still pending after install (exit 2): " + out.stdout.trim())
    }
    if !out.success { return Err(common::failure("windows update install", out)) }
    // The task's last search found nothing pending.
    stamp(params)?
    Ok(ApplyResult::Success)
}
