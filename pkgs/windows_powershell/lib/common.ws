// Helpers every windows_powershell script shares: param access, choosing
// and running a PowerShell binary, quoting, and input validation.
use value
use fs
use path
use shell
use sys
use env

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
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    let cmd = dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file)
    let opts = Value::Map(#{ "timeout": Value::Int(seconds) })
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
