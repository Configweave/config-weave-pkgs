// Helpers every windows_packages script shares: param access, running
// PowerShell, finding the package managers, validation and update stamps.
use value
use fs
use path
use shell
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

// winget is an App Installer (MSIX) app, so SYSTEM has no winget on PATH.
// The newest App Installer copy under WindowsApps is used instead. That
// copy only starts when the Visual C++ 2015-2022 runtime is installed
// machine-wide (it fails with 0xC0000135, DLL not found); a winget that
// cannot start counts as missing.
fn winget_ps() -> string {
    "$winget = (Get-Command winget -ErrorAction SilentlyContinue).Source\n" +
    "if (-not $winget) {{\n" +
    "  $winget = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps\\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\\winget.exe') -ErrorAction SilentlyContinue | Sort-Object {{ [version]($_.Directory.Name -split '_')[1] }} | Select-Object -Last 1 -ExpandProperty FullName\n" +
    "  if ($winget) {{ try {{ $null = & $winget --version }} catch {{ }}; if ($LASTEXITCODE -ne 0) {{ $winget = $null }} }}\n" +
    "}}\n" +
    "if (-not $winget) {{ exit 9009 }}\n"
}

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

fn last_lines(text: string, n: int) -> string {
    let lines: List[string] = []
    for line in text.split("\n") {
        if line.trim() != "" { lines.push(line.trim()) }
    }
    let start = if lines.len() > n { lines.len() - n } else { 0 }
    lines.slice(start, lines.len()).join(" / ")
}

// Chocolatey, scoop and winget report failures on stdout, so the error
// carries stderr, falls back to the tail of stdout, and always names the
// exit code.
fn failure(what: string, out: CmdOutput) -> string {
    if out.code == missing_code() { return what + " failed: the package manager is not installed or cannot start (winget also needs the Visual C++ 2015-2022 runtime to run as SYSTEM)" }
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
