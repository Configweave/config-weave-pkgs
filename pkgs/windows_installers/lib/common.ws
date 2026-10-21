// Helpers every windows_installers script shares: param access, running
// PowerShell and installers, fetching and verifying installer files, and
// input validation.
use value
use fs
use path
use http
use hash
use shell
use time

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let items: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs {
                if let Some(s) = x.as_string() { items.push(s) }
            }
        }
    }
    items
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// Installers report failures on either stream or only through the exit
// code, so the error carries stderr, falls back to stdout, and always
// names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// Runs a script from a temp .ps1 with -File, so the script may hold any
// quote character and never appears on a command line. Values that came
// from params travel in `env` (read as $env:CW_…).
//
// The file carries a UTF-8 BOM, since Windows PowerShell 5.1 reads a
// BOM-less script as the ANSI code page. Output is forced to UTF-8 because
// 5.1 otherwise re-encodes native output to the OEM code page, and the host
// drops output that is not valid UTF-8. Installers can run for a long time,
// so the timeout is two hours.
fn run_ps(script: string, env: Map[string, Value]) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-installers.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\""
    let out = shell::run(cmd, Value::Map(#{ "env": Value::Map(env), "timeout": Value::Int(7200) }))
    fs::delete_dir(dir)?
    out
}

// Start-Process an executable and wait for it, returning its exit code in
// the CmdOutput. The executable and its argument string travel in the
// environment, so neither is re-quoted on the way.
fn start_process(exe: string, args: string) -> Result[CmdOutput, string] {
    let script = "$a = @{{ FilePath = $env:CW_EXE; Wait = $true; PassThru = $true }}\n" +
        "if ([string]$env:CW_ARGS -ne '') {{ $a.ArgumentList = $env:CW_ARGS }}\n" +
        "$p = Start-Process @a\n" +
        "exit $p.ExitCode\n"
    run_ps(script, #{ "CW_EXE": Value::String(exe), "CW_ARGS": Value::String(args) })
}

fn is_url(src: string) -> bool {
    let l = src.to_lower()
    l.starts_with("http://") || l.starts_with("https://")
}

// Downloads are kept, one directory per URL, under ProgramData: an MSI's
// source location is recorded at install and needed again for repair,
// modify and minor upgrades, so it must not sit in a temp directory that
// is cleaned out, and two URLs must never share one file name.
fn cache_dir() -> string { "C:\\ProgramData\\config-weave\\installers" }

fn url_file_name(url: string, fallback: string) -> string {
    let p = url
    if let Some(i) = p.find("?") { p = p.slice(0, i) }
    if let Some(i) = p.find("#") { p = p.slice(0, i) }
    let parts = p.split("/")
    let last = parts.get(parts.len() - 1).unwrap_or("")
    let allowed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_"
    let out = ""
    for c in last.chars() {
        if allowed.contains(str(c)) { out = out + str(c) } else { out = out + "_" }
    }
    if out == "" || out.starts_with(".") { return fallback }
    out
}

fn sha256_matches(file: string, want: string) -> Result[bool, string] {
    Ok(hash::sha256_file(file)?.to_lower() == want.to_lower())
}

// A local path to run: a URL is fetched into the cache (and fetched again
// unless the cached copy already matches `sha256`); a local path is used as
// it is. Either way the file must exist, and must match `sha256` when set,
// before anything runs it.
fn local_file(src: string, sha256: string, fallback_name: string) -> Result[string, string] {
    if is_url(src) {
        let dir = path::join(cache_dir(), hash::sha256(src).slice(0, 16))
        fs::mkdir(dir)?
        let f = path::join(dir, url_file_name(src, fallback_name))
        if sha256 != "" && fs::is_file(f) && sha256_matches(f, sha256)? { return Ok(f) }
        // Downloaded beside the target and moved into place, so a failed
        // download never leaves a truncated installer under the real name.
        let part = f + ".part"
        http::download(src, part, Value::Null)?
        if sha256 != "" && !sha256_matches(part, sha256)? {
            let got = hash::sha256_file(part)?
            fs::delete(part)?
            return Err("the file downloaded from " + src + " has SHA-256 " + got + ", expected " + sha256.to_lower())
        }
        if fs::is_file(f) { fs::delete(f)? }
        fs::move(part, f)?
        return Ok(f)
    }
    if !fs::is_file(src) { return Err("installer file '" + src + "' does not exist") }
    if sha256 != "" && !sha256_matches(src, sha256)? {
        return Err("'" + src + "' has SHA-256 " + hash::sha256_file(src)? + ", expected " + sha256.to_lower())
    }
    Ok(src)
}

// ---------------------------------------------------------------------
// Validation (run by both check and apply, so check fails loudly too)
// ---------------------------------------------------------------------

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// A path that is placed inside double quotes on an msiexec command line.
fn quotable_path(label: string, value: string) -> Result[unit, string] {
    if value.contains("\"") { return Err("'" + label + "' must not contain a double quote, got '" + value + "'") }
    single_line(label, value)
}

fn is_hex(s: string) -> bool {
    let digits = "0123456789abcdefABCDEF"
    for c in s.chars() {
        if !digits.contains(str(c)) { return false }
    }
    true
}

// {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}, the form the Uninstall key and
// msiexec /x use.
fn validate_guid(label: string, value: string) -> Result[unit, string] {
    let bad = Err("'" + label + "' must be a braced GUID like {{23170F69-40C1-2702-2409-000001000000}}, got '" + value + "'")
    if value.len() != 38 || !value.starts_with("{{") || !value.ends_with("}}") { return bad }
    let parts = value.slice(1, 37).split("-")
    if parts.len() != 5 { return bad }
    let lens = [8, 4, 4, 4, 12]
    let i = 0
    for p in parts {
        if p.len() != lens.get(i).unwrap_or(0) || !is_hex(p) { return bad }
        i = i + 1
    }
    Ok(())
}

fn validate_sha256(value: string) -> Result[unit, string] {
    if value == "" { return Ok(()) }
    if value.len() != 64 || !is_hex(value) { return Err("'sha256' must be 64 hex digits, got '" + value + "'") }
    Ok(())
}

// Install markers can lag the installer's exit (an uninstaller that copies
// itself to %TEMP% and re-launches returns at once). Polls `probe` until it
// reports `want`, for up to `secs`.
fn wait_for_marker(want: bool, secs: int, probe: fn() -> Result[bool, string]) -> Result[bool, string] {
    let deadline = time::now_millis() + secs * 1000
    loop {
        if probe()? == want { return Ok(true) }
        if time::now_millis() > deadline { return Ok(false) }
        time::sleep(1000)
    }
    Ok(false)
}
