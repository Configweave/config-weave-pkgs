// Helpers every windows_packages script shares: param access, running
// PowerShell, finding the package managers, validation and update stamps.
use value
use fs
use path
use shell
use time
use http
use hash
use log
use regex

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

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn get_int(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(n) = v.as_int() { return n } }
    0
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

// The exit code every script uses for "this package manager is not
// installed", as cmd.exe does for an unknown command.
fn missing_code() -> int { 9009 }

// PowerShell that resolves each manager into a variable, or exits 9009.
// The guest agent's PATH predates an install made earlier in the same run,
// so each manager's default location is tried after PATH.
fn choco_ps() -> string {
    "$choco = (Get-Command choco -ErrorAction SilentlyContinue).Source\n" +
    "if (-not $choco) {{ $root = if ($env:ChocolateyInstall) {{ $env:ChocolateyInstall }} else {{ Join-Path $env:ProgramData 'chocolatey' }}; $c = Join-Path $root 'bin\\choco.exe'; if (Test-Path -LiteralPath $c) {{ $choco = $c }} }}\n" +
    "if (-not $choco) {{ exit 9009 }}\n" +
    // Chocolatey 1.x `choco list` searches the remote sources unless told
    // --local-only; 2.x lists only what is installed and rejects the flag.
    "$chocoLocal = @()\n" +
    "try {{ if ([int]((& $choco --version) -split '\\.')[0] -lt 2) {{ $chocoLocal = @('--local-only') }} }} catch {{ }}\n"
}

fn scoop_root_ps() -> string {
    "$scoopRoot = if ($env:SCOOP) {{ $env:SCOOP }} else {{ Join-Path $env:USERPROFILE 'scoop' }}\n"
}

// Scoop's shim executables cannot start for SYSTEM (its profile lives under
// System32, and the shims fail with "Cannot open shim file for read"), and
// scoop needs git for every bucket operation. So scoop's own git and its
// shims directory go first on PATH for the scoop process.
fn scoop_ps() -> string {
    scoop_root_ps() +
    "foreach ($d in @((Join-Path $scoopRoot 'shims'), (Join-Path $scoopRoot 'apps\\git\\current\\cmd'))) {{ if (Test-Path -LiteralPath $d) {{ $env:PATH = $d + ';' + $env:PATH }} }}\n" +
    "$scoop = (Get-Command scoop -ErrorAction SilentlyContinue).Source\n" +
    "if (-not $scoop) {{ $s = Join-Path $scoopRoot 'shims\\scoop.ps1'; if (Test-Path -LiteralPath $s) {{ $scoop = $s }} }}\n" +
    "if (-not $scoop) {{ exit 9009 }}\n"
}

// winget is an App Installer (MSIX) app, so SYSTEM — and any account that
// never logged on interactively — has no winget on PATH. Every winget
// script uses the newest winget.exe under WindowsApps, as winget_installed
// does, and PATH (a user's alias, or a shim) only when there is none. That
// copy only starts when the Visual C++ 2015-2022 runtime is installed
// machine-wide (it fails with 0xC0000135, DLL not found); a winget that
// cannot start counts as missing.
fn winget_ps() -> string {
    "$winget = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps\\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\\winget.exe') -ErrorAction SilentlyContinue | Sort-Object {{ [version]($_.Directory.Name -split '_')[1] }} | Select-Object -Last 1 -ExpandProperty FullName\n" +
    "if (-not $winget) {{ $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source }}\n" +
    "if ($winget) {{ try {{ $null = & $winget --version }} catch {{ }}; if ($LASTEXITCODE -ne 0) {{ $winget = $null }} }}\n" +
    "if (-not $winget) {{ exit 9009 }}\n"
}

// winget exit codes a step maps rather than reports as a failure.
// APPINSTALLER_CLI_ERROR_INSTALL_REBOOT_REQUIRED_TO_FINISH (0x8A150109).
fn winget_reboot_code() -> int { -1978334967 }
// APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (0x8A15002B): already at the
// newest version the source offers.
fn winget_no_upgrade_code() -> int { -1978335189 }
// APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND (0x8A150014): `winget list`
// matched nothing.
fn winget_none_found_code() -> int { -1978335212 }

// Runs a script from a temp .ps1 with -File, so the script may hold any
// quote character and never appears on a command line. Values that came
// from params travel in `env` (read as $env:CW_…), never interpolated into
// the script.
//
// The file carries a UTF-8 BOM, since Windows PowerShell 5.1 reads a
// BOM-less script as the ANSI code page. Output is forced to UTF-8 because
// 5.1 otherwise re-encodes native output to the OEM code page, and the host
// drops all output that is not valid UTF-8: one package named with an
// accent would empty a whole listing.
fn run_ps(script: string, env: Map[string, Value], seconds: int) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-packages.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\n" +
        "try {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false; $OutputEncoding = [Console]::OutputEncoding }} catch {{ }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\""
    let out = shell::run(cmd, Value::Map(#{ "env": Value::Map(env), "timeout": Value::Int(seconds) }))
    fs::delete_dir(dir)?
    out
}

// A query: five minutes.
fn query(script: string, env: Map[string, Value]) -> Result[CmdOutput, string] { run_ps(script, env, 300) }

// An install or upgrade: two hours.
fn action(script: string, env: Map[string, Value]) -> Result[CmdOutput, string] { run_ps(script, env, 7200) }

// winget redraws a spinner and progress bars with carriage returns, so
// lines are split on \r too, and a line with no letter or with a bar's
// block characters is dropped: what is left is what winget said.
fn last_lines(text: string, n: int) -> string {
    let lines: List[string] = []
    for line in text.replace("\r", "\n").replace("\u{8}", "\n").split("\n") {
        let t = line.trim()
        if t != "" && !t.contains("\u{2588}") && !t.contains("\u{2592}") && regex::is_match("[A-Za-z]", t) { lines.push(t) }
    }
    let start = if lines.len() > n { lines.len() - n } else { 0 }
    lines.slice(start, lines.len()).join(" / ")
}

// Chocolatey, scoop and winget report failures on stdout, so the error
// carries stderr, falls back to the tail of stdout, and always names the
// exit code.
fn failure(what: string, out: CmdOutput) -> string {
    if out.code == missing_code() { return what + " failed: the package manager is not installed or cannot start (for winget, run windows_packages.winget_installed first: as SYSTEM winget also needs the Visual C++ 2015-2022 runtime)" }
    let detail = last_lines(out.stderr, 10)
    if detail == "" { detail = last_lines(out.stdout, 10) }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// ---------------------------------------------------------------------
// Validation (run by both check and apply, so check fails loudly too)
// ---------------------------------------------------------------------

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// A package, bucket or source name handed to a manager as an operand:
// letters, digits and . _ - + only, and never starting with '-' (it would
// be read as an option) or '.'.
fn validate_name(label: string, value: string) -> Result[unit, string] {
    if value == "" { return Err("missing '" + label + "' parameter") }
    let allowed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_+"
    for c in value.chars() {
        if !allowed.contains(str(c)) { return Err("'" + label + "' may only hold letters, digits, '.', '-', '_' and '+', got '" + value + "'") }
    }
    if value.starts_with("-") || value.starts_with(".") { return Err("'" + label + "' must not start with '-' or '.', got '" + value + "'") }
    Ok(())
}

fn validate_version(value: string) -> Result[unit, string] {
    if value == "" { return Ok(()) }
    validate_name("version", value)
}

// ---------------------------------------------------------------------
// Update windows (*_updated, *_cache_updated)
// ---------------------------------------------------------------------

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
// Every version decision goes through version_ok, so a richer syntax
// (ranges) replaces this one function.
// ---------------------------------------------------------------------

// -1, 0 or 1 as `a` sorts before, with or after `b`. A leading v is
// ignored, the dotted core compares numerically with a missing part counting
// as 0 (24.08 == 24.08.0), and a prerelease sorts before its release
// (1.10.0-preview < 1.10.0), identifiers compared as semver does.
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
    if let Some(i) = s.find("+") { s = s.slice(0, i) }
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
// accepts any version; `at_least` makes it a floor, otherwise it must match.
// A match compares numerically, so 24.08 matches 24.08.0; a version that is
// not dotted numbers (winget's "Unknown") matches only itself, exactly.
fn version_ok(have: string, want: string, at_least: bool) -> bool {
    if have == "" { return false }
    if want == "" { return true }
    if have.to_lower() == want.to_lower() { return true }
    let c = version_cmp(have, want)
    if at_least { return c >= 0 }
    c == 0
}

// ---------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------

// http::download is retried and checked against the expected size and
// sha256 when they are known (0 and "" skip them). Its rustls client fails
// some Microsoft CDNs (aka.ms, download.visualstudio.microsoft.com) with
// "peer closed connection without sending TLS close_notify", so when every
// host attempt fails the file is fetched once more through Windows' own
// Invoke-WebRequest, whose result is checked here. A digest mismatch is not
// a transport problem and gets no fallback. Callers download into a temp
// directory they delete afterwards, so a partial file never outlives the
// step.
fn download(url: string, file: string, size: int, sha256: string) -> Result[unit, string] {
    let opts = #{ "timeout": Value::Int(1800), "retries": Value::Int(3) }
    if size > 0 { opts.insert("size", Value::Int(size)) }
    if sha256 != "" { opts.insert("sha256", Value::String(sha256)) }
    log::info("downloading " + url)
    let e = match http::download(url, file, Value::Map(opts)) {
        Ok(_) => return Ok(()),
        Err(e) => e
    }
    if e.contains("sha256 mismatch") { return Err(e) }
    log::warn(e + "; trying Invoke-WebRequest")
    let out = run_ps("$ProgressPreference = 'SilentlyContinue'\n[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12\nInvoke-WebRequest -Uri $env:CW_URL -OutFile $env:CW_FILE -UseBasicParsing\n",
        #{ "CW_URL": Value::String(url), "CW_FILE": Value::String(file) }, 1800)?
    let last = if !out.success { failure("Invoke-WebRequest", out) } else {
        let n = if let Some(v) = fs::metadata(file)?.get("size") { v.as_int().unwrap_or(0) } else { 0 }
        if n == 0 || (size > 0 && n != size) {
            "got " + str(n) + " bytes" + (if size > 0 { ", expected " + str(size) } else { "" })
        } else if sha256 != "" && hash::sha256_file(file)? != sha256.to_lower() {
            "sha256 mismatch"
        } else {
            ""
        }
    }
    if last == "" { return Ok(()) }
    if fs::exists(file) { fs::delete(file)? }
    Err(e + "; Invoke-WebRequest: " + last)
}
