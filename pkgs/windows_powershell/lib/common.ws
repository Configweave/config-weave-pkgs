// Helpers every windows_powershell script shares: param access, choosing
// and running a PowerShell binary, quoting, and input validation.
use value
use fs
use path
use shell
use sys
use env
use hash
use time
use http
use json

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

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn resolved_edition(edition: string) -> string {
    if edition != "auto" { return edition }
    if sys::family() == "windows" { "windows_powershell" } else { "pwsh" }
}

// shell::powershell probes `powershell` before `pwsh`, so on Windows it can
// only ever reach Windows PowerShell 5.1. Every script here picks its own
// binary instead.
//
// The MSI's PATH change is invisible to an already-running process, so a
// PowerShell installed earlier in this same run cannot be found by name.
// The MSI's own root is preferred, then any other root beside it, and PATH
// last.
fn pwsh_binary(preview: bool) -> string {
    if sys::family() != "windows" {
        if preview { return "pwsh-preview" }
        return "pwsh"
    }
    let msi_root = if preview { "C:\\Program Files\\PowerShell\\7-preview\\pwsh.exe" } else { "C:\\Program Files\\PowerShell\\7\\pwsh.exe" }
    if fs::is_file(msi_root) { return msi_root }
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

// Whether a program name resolves on PATH, or a path names a file. This is
// what separates "that PowerShell is not installed" (a fact run 1 meets
// before the install step has applied) from "the query failed".
fn on_path(program: string) -> bool {
    if program.contains("/") || program.contains("\\") { return fs::is_file(program) }
    let windows = sys::family() == "windows"
    for dir in env::path_split(env::get("PATH").unwrap_or("")) {
        if dir == "" { continue }
        if fs::is_file(path::join(dir, program)) { return true }
        if windows && fs::is_file(path::join(dir, program + ".exe")) { return true }
    }
    false
}

fn ps_installed(edition: string) -> bool { on_path(ps_exe(edition)) }

fn dq(s: string) -> string { "\"" + s + "\"" }

// A PowerShell single-quoted literal. PowerShell also treats the curly
// quotes U+2018 to U+201B as single quotes, so they are doubled too.
fn ps_q(s: string) -> string {
    let out = s.replace("'", "''")
    for quote in ["\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"] {
        out = out.replace(quote, quote + quote)
    }
    "'" + out + "'"
}

// Each item is quoted individually — quoting a pre-joined string would let
// ps_q escape the separator's own quotes and mangle the list.
fn ps_list(items: List[string]) -> string {
    let quoted: List[string] = []
    for item in items { quoted.push(ps_q(item)) }
    quoted.join(",")
}

// A POSIX shell single-quoted literal, for shell::bash.
fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

// WCL symbols are lower_snake_case; the values they name are PascalCase.
fn pascal(symbol: string) -> string {
    let out = ""
    for word in symbol.split("_") {
        if word != "" { out = out + word.slice(0, 1).to_upper() + word.slice(1, word.len()) }
    }
    out
}

// Many tools report failures on stdout, so the error carries stderr, falls
// back to stdout, and always names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// -File with a temp .ps1 sidesteps shell-words quoting entirely, so the
// script may be multi-line and hold any quote character. -ExecutionPolicy is
// a Windows-only switch — and it is what keeps these invocations working
// under a policy this very package may have set.
//
// The script is written with a UTF-8 BOM: Windows PowerShell 5.1 reads a
// BOM-less script as the ANSI code page and would mangle any non-ASCII name
// in it. Output is forced to UTF-8 because 5.1 otherwise re-encodes it to the
// OEM code page, and the host drops output that is not valid UTF-8.
//
// Every invocation carries a timeout. A resource that can hang forever is a
// defect: the timeout kills the child and surfaces an Err, which the engine
// reports as a failed step naming this resource.
fn run_ps_with(edition: string, script: string, seconds: int, streaming: bool) -> Result[CmdOutput, string] {
    run_ps_env_with(edition, script, #{}, seconds, streaming)
}

// Values that came from params travel in `env` (read as $env:CW_…), never
// interpolated into the script.
fn run_ps_env_with(edition: string, script: string, vars: Map[string, Value], seconds: int, streaming: bool) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    let cmd = dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file)
    let opts = Value::Map(#{ "timeout": Value::Int(seconds), "env": Value::Map(vars) })
    let out = if streaming { shell::run_streaming(cmd, opts) } else { shell::run(cmd, opts) }
    fs::delete_dir(dir)?
    out
}

fn run_ps(edition: string, script: string) -> Result[CmdOutput, string] {
    run_ps_with(edition, script, 300, false)
}

// Output streamed into the log as it arrives, for installs that pull from the
// network and can run for minutes.
fn run_ps_streaming(edition: string, script: string, seconds: int) -> Result[CmdOutput, string] {
    run_ps_with(edition, script, seconds, true)
}

fn run_ps_streaming_env(edition: string, script: string, vars: Map[string, Value], seconds: int) -> Result[CmdOutput, string] {
    run_ps_env_with(edition, script, vars, seconds, true)
}

// winget is an App Installer (MSIX) app, so SYSTEM — and any account that
// never logged on interactively — has no winget on PATH. The newest copy
// under WindowsApps is used, PATH (a user's alias, or a shim) only when
// there is none. That copy starts only once the Visual C++ 2015-2022 runtime
// is installed machine-wide (it fails with 0xC0000135, DLL not found); a
// winget that cannot start exits 9009, as cmd.exe does for an unknown
// command. Kept in step with windows_packages' own locator.
fn winget_ps() -> string {
    "$winget = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps\\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\\winget.exe') -ErrorAction SilentlyContinue | Sort-Object {{ [version]($_.Directory.Name -split '_')[1] }} | Select-Object -Last 1 -ExpandProperty FullName\n" +
    "if (-not $winget) {{ $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source }}\n" +
    "if ($winget) {{ try {{ $null = & $winget --version }} catch {{ }}; if ($LASTEXITCODE -ne 0) {{ $winget = $null }} }}\n" +
    "if (-not $winget) {{ exit 9009 }}\n"
}

fn winget_missing_code() -> int { 9009 }
// APPINSTALLER_CLI_ERROR_INSTALL_REBOOT_REQUIRED_TO_FINISH (0x8A150109).
fn winget_reboot_code() -> int { -1978334967 }
// APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (0x8A15002B): already at the
// newest version the source offers.
fn winget_no_upgrade_code() -> int { -1978335189 }

// A read-only query. None means the edition is not installed, which is a fact
// rather than a failure: run 1 checks every step before the install step has
// applied. A query that ran and failed is an error, never "absent", so a
// broken PowerShell cannot make an :absent step look converged.
fn query(edition: string, script: string) -> Result[Option[string], string] {
    if !ps_installed(edition) { return Ok(None) }
    let out = run_ps(edition, script)?
    if !out.success { return Err(failure("the PowerShell query (" + ps_exe(edition) + ")", out)) }
    Ok(Some(out.stdout.trim()))
}

fn not_installed(edition: string) -> string {
    "PowerShell edition :" + resolved_edition(edition) + " is not installed (no '" + ps_exe(edition) + "' found)"
}

fn lines_of(text: string) -> List[string] {
    let out: List[string] = []
    for line in text.split("\n") {
        let trimmed = line.trim()
        if trimmed != "" { out.push(trimmed) }
    }
    out
}

// ---------------------------------------------------------------------
// Validation (run by both check and apply, so check fails loudly too)
// ---------------------------------------------------------------------

fn require(label: string, value: string) -> Result[unit, string] {
    if value == "" { return Err("missing '" + label + "' parameter") }
    Ok(())
}

// A value written into a line-based file (a profile marker, a config line).
fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// A name that becomes one path segment.
fn path_segment(label: string, value: string) -> Result[unit, string] {
    require(label, value)?
    if value.contains("/") || value.contains("\\") { return Err("'" + label + "' must not contain a path separator, got '" + value + "'") }
    if value.starts_with(".") { return Err("'" + label + "' must not start with '.', got '" + value + "'") }
    single_line(label, value)
}

// A value handed to a PowerShell -Name, which treats *?[] as wildcards.
fn no_wildcards(label: string, value: string) -> Result[unit, string] {
    for c in ["*", "?", "[", "]"] {
        if value.contains(c) { return Err("'" + label + "' must not contain the wildcard character '" + c + "', got '" + value + "'") }
    }
    single_line(label, value)
}

// A version string that reaches a command line: digits, letters, '.', '-',
// '+' and '~' only.
fn version_chars(label: string, value: string) -> Result[unit, string] {
    let allowed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+~"
    for c in value.chars() {
        if !allowed.contains(str(c)) { return Err("'" + label + "' may only hold letters, digits, '.', '-', '+' and '~', got '" + value + "'") }
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Update windows (modules_updated, help_updated)
// ---------------------------------------------------------------------

// The default stamp is per target: two steps that update different editions,
// scopes or module sets must not share one window. `parts` names the target;
// lists in it should already be sorted.
fn stamp_path(params: Value, base: string, parts: List[string]) -> string {
    let explicit = param_str(params, "stamp_path", "")
    if explicit != "" { return explicit }
    let tag = hash::sha256(parts.join("|")).slice(0, 12)
    let dir = if sys::family() == "windows" { "C:/ProgramData/config-weave" } else { "/var/lib/config-weave" }
    dir + "/" + base + "-" + tag
}

fn sorted(items: List[string]) -> List[string] {
    let out = items.clone()
    out.sort()
    out
}

// A `duration` param arrives as base nanoseconds.
fn stamp_fresh(stamp: string, params: Value) -> Result[bool, string] {
    if !fs::is_file(stamp) { return Ok(false) }
    let max_age = param_int(params, "max_age", 24 * 3600 * 1000000000) / 1000000000
    let modified = 0
    if let Some(m) = fs::metadata(stamp)?.get("modified") { modified = m.as_int().unwrap_or(0) }
    Ok(time::now_millis() / 1000 - modified <= max_age)
}

// Rewriting the stamp truncates it and so refreshes its mtime, which is what
// advances the window — no separate touch is needed.
fn touch_stamp(stamp: string, label: string) -> Result[unit, string] {
    let parent = path::parent(stamp)
    if parent != "" { fs::mkdir(parent)? }
    fs::write(stamp, label + "\n")
}

// ---------------------------------------------------------------------
// Versions
//
// Every version decision a resource makes goes through version_ok, so a
// richer syntax (ranges) replaces this one function.
// ---------------------------------------------------------------------

// -1, 0 or 1 as `a` sorts before, with or after `b`. The dotted core
// compares numerically, a missing part counting as 0 (7.5 == 7.5.0). A
// prerelease sorts before its release (7.6.0-rc.1 < 7.6.0), and two
// prereleases compare identifier by identifier, numbers numerically and
// words alphabetically (preview.5 < preview.10 < rc.1), as semver orders them.
fn version_cmp(a: string, b: string) -> int {
    let ap = split_pre(a)
    let bp = split_pre(b)
    let c = parts_cmp(ap[0].split("."), bp[0].split("."), true)
    if c != 0 { return c }
    if ap[1] == bp[1] { return 0 }
    if ap[1] == "" { return 1 }
    if bp[1] == "" { return -1 }
    parts_cmp(ap[1].split("."), bp[1].split("."), false)
}

fn split_pre(v: string) -> List[string] {
    let s = v.trim()
    if s.starts_with("v") || s.starts_with("V") { s = s.slice(1, s.len()) }
    let plus = s.find("+")
    if let Some(i) = plus { s = s.slice(0, i) }
    if let Some(i) = s.find("-") { return [s.slice(0, i), s.slice(i + 1, s.len())] }
    [s, ""]
}

fn parts_cmp(a: List[string], b: List[string], pad: bool) -> int {
    let n = if a.len() > b.len() { a.len() } else { b.len() }
    let i = 0
    while i < n {
        if !pad && i >= a.len() { return -1 }
        if !pad && i >= b.len() { return 1 }
        let x = a.get(i).unwrap_or("0")
        let y = b.get(i).unwrap_or("0")
        let xn = x.parse_int()
        let yn = y.parse_int()
        if xn.is_some() && yn.is_some() {
            let xi = xn.unwrap()
            let yi = yn.unwrap()
            if xi < yi { return -1 }
            if xi > yi { return 1 }
        } else if xn.is_some() {
            return -1
        } else if yn.is_some() {
            return 1
        } else {
            if x < y { return -1 }
            if x > y { return 1 }
        }
        i = i + 1
    }
    0
}

// Whether an installed version satisfies the wanted one. An empty `wanted`
// accepts any build; otherwise `at_least` makes it a floor (a resolved
// "latest", which a newer build also satisfies) and its absence an exact
// match.
fn version_ok(installed: string, wanted: string, at_least: bool) -> bool {
    if installed == "" { return false }
    if wanted == "" { return true }
    let c = version_cmp(installed, wanted)
    if at_least { return c >= 0 }
    c == 0
}

// The release metadata PowerShell publishes in its repository
// (tools/metadata.json): StableReleaseTag, PreviewReleaseTag and the
// LTSReleaseTag list. :lts takes the oldest LTS line still listed, which is
// what packages.microsoft.com ships as powershell-lts and what
// aka.ms/pwsh-buildinfo-lts answers. raw.githubusercontent.com is used
// rather than aka.ms/pwsh-buildinfo-<channel>, whose origin regularly drops
// TLS connections without a close_notify, and rather than the GitHub API,
// which rate-limits. A `url` override may serve either that document or a
// buildinfo one ({ "ReleaseTag": "v7.6.7" }).
fn latest_release(channel: string, url: string) -> Result[string, string] {
    let src = if url != "" { url } else { "https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json" }
    let what = "resolving the latest :" + channel + " PowerShell release from " + src
    let hint = " (version = \"latest\" needs that URL reachable; pin a version, or point latest_url at a mirror, to work offline)"
    let last = ""
    let attempt = 1
    while attempt <= 3 {
        let resp = http::get(src, Value::Map(#{ "timeout": Value::Int(60), "redirects": Value::Bool(true) }))
        if let Ok(r) = resp {
            if r.status == 200 { return release_tag(r.body, channel, what + " failed: ", hint) }
            last = "HTTP " + str(r.status)
            if r.status >= 400 && r.status < 500 { attempt = 3 }
        } else if let Err(e) = resp {
            last = e
        }
        attempt = attempt + 1
        if attempt <= 3 { time::sleep(3000) }
    }
    Err(what + " failed: " + last + hint)
}

fn tag_of(v: Value) -> string {
    let s = v.as_string().unwrap_or("").trim()
    if s.starts_with("v") { return s.slice(1, s.len()) }
    s
}

fn release_tag(body: string, channel: string, fail: string, hint: string) -> Result[string, string] {
    let parsed = json::parse(body)
    if parsed.is_err() { return Err(fail + "the answer is not JSON" + hint) }
    let doc = parsed?
    let tag = ""
    if let Some(t) = doc.get("ReleaseTag") { if doc.get("StableReleaseTag").is_none() { tag = tag_of(t) } }
    if tag == "" {
        if channel == "preview" {
            tag = tag_of(doc.get("PreviewReleaseTag").unwrap_or(Value::Null))
        } else if channel == "lts" {
            for t in doc.get("LTSReleaseTag").unwrap_or(Value::Null).as_list().unwrap_or([]) {
                let v = tag_of(t)
                if v != "" && (tag == "" || version_cmp(v, tag) < 0) { tag = v }
            }
        } else {
            tag = tag_of(doc.get("StableReleaseTag").unwrap_or(Value::Null))
        }
    }
    if tag == "" { return Err(fail + "the answer names no :" + channel + " release" + hint) }
    version_chars("the resolved release", tag)?
    Ok(tag)
}
