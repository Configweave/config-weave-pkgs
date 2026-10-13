// Helpers every windows_defender script shares: param access, quoting, and
// running PowerShell against a Defender that is known to be present.
use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
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

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// A PowerShell single-quoted literal. PowerShell also treats the curly
// quotes U+2018 to U+201B as single quotes, so they are doubled too.
fn ps_q(s: string) -> string {
    let out = s.replace("'", "''")
    for quote in ["\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"] {
        out = out.replace(quote, quote + quote)
    }
    "'" + out + "'"
}

// The error carries stderr, falls back to stdout, and names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// Defender has to be installed and its service running for any of the
// MpPreference cmdlets to mean anything. A third-party antivirus product
// stops WinDefend, and Server can have the feature removed entirely.
fn guard() -> string {
    "if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) {{ " +
    "throw 'Microsoft Defender Antivirus is not installed (no Defender PowerShell module); install the Windows-Defender feature' }}; " +
    "$wd = Get-Service -Name WinDefend -ErrorAction SilentlyContinue; " +
    "if ($null -eq $wd -or [string]$wd.Status -ne 'Running') {{ " +
    "throw 'the Microsoft Defender Antivirus service (WinDefend) is not running; another antivirus product may have taken over' }}; "
}

// Run `script` after the guard. A failure is reported as its message alone,
// without the source line PowerShell 5.1 prints after it.
// Success exits 0 explicitly: the exit code would otherwise follow $? of
// the last statement, which a deliberately caught not-found leaves false.
fn ps(what: string, script: string) -> Result[string, string] {
    let full = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; " +
        "try {{ " + guard() + script + "\nexit 0 }} catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}"
    let out = shell::powershell(full, Value::Null)?
    if !out.success { return Err(failure(what, out)) }
    Ok(out.stdout.trim())
}
