use value
use fs
use path
use shell
use sys
use time

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let out: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(items) = v.as_list() {
            for item in items {
                if let Some(s) = item.as_string() { out.push(s) }
            }
        }
    }
    out
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

// Each item is quoted individually — quoting a pre-joined string would let
// ps_q escape the separator's own quotes and mangle the list.
fn ps_list(items: List[string]) -> string {
    let quoted: List[string] = []
    for item in items { quoted.push(ps_q(item)) }
    quoted.join(",")
}

// Every PowerShell invocation carries a timeout. A resource that can hang
// forever is a defect: the timeout kills the child and surfaces an Err, which
// the engine reports as a failed step naming this resource.
fn ps_argv(edition: string, file: string) -> string {
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file)
}

fn run_ps(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let out = shell::run(ps_argv(edition, file), Value::Map(#{ "timeout": Value::Int(300) }))
    fs::delete_dir(dir)?
    out
}

fn run_ps_streaming(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let out = shell::run_streaming(ps_argv(edition, file), Value::Map(#{ "timeout": Value::Int(1800) }))
    fs::delete_dir(dir)?
    out
}

fn pascal(symbol: string) -> string {
    let out = ""
    for word in symbol.split("_") {
        if word != "" { out = out + word.slice(0, 1).to_upper() + word.slice(1, word.len()) }
    }
    out
}

fn provider(params: Value) -> Result[string, string] {
    let requested = param_str(params, "provider", "auto")
    if requested == "psresourceget" { return Ok("psresourceget") }
    if requested == "powershellget" { return Ok("powershellget") }
    if requested != "auto" { return Err("invalid 'provider' value '" + requested + "'") }
    // Probing the cmdlet rather than listing the module: PSResourceGet ships
    // inside PowerShell 7 and stays usable even when PSModulePath has been
    // overridden so that Get-Module -ListAvailable no longer finds it. Getting
    // this wrong falls back to the v2 cmdlets, which under pwsh on Windows go
    // through the Windows PowerShell compatibility layer and can block.
    let probe = "if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {{ Write-Output 'psresourceget' }} else {{ Write-Output 'powershellget' }}"
    // A probe that cannot run at all means the target PowerShell is not
    // installed yet — run 1 checks every step before the install step has
    // applied — so fall back to the edition's usual generation.
    let out = run_ps(param_str(params, "edition", "auto"), probe)
    if let Ok(result) = out {
        if result.success {
            let detected = result.stdout.trim()
            if detected != "" { return Ok(detected) }
        }
    }
    if resolved_edition(param_str(params, "edition", "auto")) == "windows_powershell" { return Ok("powershellget") }
    Ok("psresourceget")
}

// The stamp file's mtime records the last update this resource performed.
fn stamp_path(params: Value) -> string {
    let explicit = param_str(params, "stamp_path", "")
    if explicit != "" { return explicit }
    if sys::family() == "windows" { return "C:/ProgramData/config-weave/powershell-modules-updated" }
    "/var/lib/config-weave/powershell-modules-updated"
}

// A `duration` param arrives as base nanoseconds.
fn max_age_secs(params: Value) -> int {
    param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
}

fn last_run(params: Value) -> Result[int, string] {
    let meta = fs::metadata(stamp_path(params))?
    if let Some(m) = meta.get("modified") {
        if let Some(ts) = m.as_int() { return Ok(ts) }
    }
    Ok(0)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let stamp = stamp_path(params)
    if !fs::is_file(stamp) { return Ok(CheckResult::NotConfigured) }
    if time::now_millis() / 1000 - last_run(params)? > max_age_secs(params) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let kind = provider(params)?
    let names = param_list(params, "names")
    let scope = pascal(param_str(params, "scope", "current_user"))
    let prerelease = param_bool(params, "prerelease", false)

    let script = ""
    if kind == "psresourceget" {
        let target = if names.is_empty() { "-Name '*'" } else { "-Name " + ps_list(names) }
        let args = " " + target + " -Scope " + scope + " -TrustRepository"
        if prerelease { args = args + " -Prerelease" }
        script = "Import-Module Microsoft.PowerShell.PSResourceGet\nUpdate-PSResource" + args
    } else {
        let target = if names.is_empty() { "" } else { " -Name " + ps_list(names) }
        let args = target + " -Force"
        if prerelease { args = args + " -AllowPrerelease" }
        script = "Update-Module" + args
    }

    let out = run_ps_streaming(param_str(params, "edition", "auto"), script)?
    if !out.success { return Err("updating modules failed: " + out.stderr.trim() + " " + out.stdout.trim()) }

    let stamp = stamp_path(params)
    let parent = path::parent(stamp)
    if parent != "" { fs::mkdir(parent)? }
    // Rewriting the stamp truncates it and so refreshes its mtime, which is
    // what advances the window — no separate touch is needed.
    fs::write(stamp, "powershell-modules\n")?
    Ok(ApplyResult::Success)
}
