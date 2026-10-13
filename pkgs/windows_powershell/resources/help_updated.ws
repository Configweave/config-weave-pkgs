use value
use common

fn edition(params: Value) -> string { common::param_str(params, "edition", "auto") }

fn stamp(params: Value) -> string {
    common::stamp_path(params, "powershell-help-updated", [
        common::resolved_edition(edition(params)),
        common::param_str(params, "scope", "all_users"),
        common::sorted(common::param_list(params, "modules")).join(","),
        common::param_str(params, "ui_culture", ""),
        common::param_str(params, "source_path", "")
    ])
}

fn check(params: Value) -> Result[CheckResult, string] {
    if common::stamp_fresh(stamp(params), params)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let ed = edition(params)
    if !common::ps_installed(ed) { return Err(common::not_installed(ed)) }
    let modules = common::param_list(params, "modules")
    for m in modules { common::no_wildcards("modules", m)? }
    let args = ""
    if !modules.is_empty() { args = " -Module " + common::ps_list(modules) }
    let culture = common::param_str(params, "ui_culture", "")
    if culture != "" { args = args + " -UICulture " + common::ps_q(culture) }
    let source = common::param_str(params, "source_path", "")
    if source != "" { args = args + " -SourcePath " + common::ps_q(source) }
    if common::param_bool(params, "force", true) { args = args + " -Force" }
    // -Scope arrived in PowerShell 6; Windows PowerShell 5.1 always writes to
    // the machine-wide help store and rejects the switch.
    if common::resolved_edition(ed) != "windows_powershell" {
        args = args + " -Scope " + common::pascal(common::param_str(params, "scope", "all_users"))
    }
    let targets = if modules.is_empty() {
        "@(Get-Module -ListAvailable | Where-Object {{ $_.HelpInfoUri }} | Select-Object -ExpandProperty Name -Unique)"
    } else {
        "@(" + common::ps_list(modules) + ")"
    }

    // Update-Help reports a non-terminating error for every module without
    // downloadable help, which is the normal case on a stock machine. The
    // errors are collected rather than silenced: each is reported, and the
    // run fails — leaving the window open — when there are at least as many
    // errors as modules it targeted, which is what "nothing updated" (no
    // network, a wrong source_path) looks like.
    let script = "$targets = " + targets + "\n$failed = @()\nUpdate-Help" + args + " -ErrorAction SilentlyContinue -ErrorVariable failed\nforeach ($e in $failed) {{ [Console]::Error.WriteLine([string]$e) }}\nif ($failed.Count -gt 0 -and $failed.Count -ge $targets.Count) {{ [Console]::Error.WriteLine(('Update-Help failed for every module: ' + $failed.Count + ' errors for ' + $targets.Count + ' modules')); exit 1 }}"
    let out = common::run_ps_streaming(ed, script, 1800)?
    if !out.success { return Err(common::failure("updating help", out)) }
    common::touch_stamp(stamp(params), "powershell-help")?
    Ok(ApplyResult::Success)
}
