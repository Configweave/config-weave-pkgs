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
    if detail == "" { return what + " failed (exit " + code_str(out.code) + ")" }
    what + " failed (exit " + code_str(out.code) + "): " + detail
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
        // http::download renames into place only a complete download that
        // matches `sha256`, so a failed one never leaves a truncated
        // installer under the real name.
        let opts = #{ "retries": Value::Int(3) }
        if sha256 != "" { opts.insert("sha256", Value::String(sha256)) }
        http::download(src, f, Value::Map(opts))?
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

// ---------------------------------------------------------------------
// Exit codes
// ---------------------------------------------------------------------

// A Windows exit code is a 32-bit DWORD, so 0x8A15002B can arrive (or be
// written in a param) as 2316632107 or as -1978335189. Both sides are
// compared as the unsigned value.
fn u32_code(n: int) -> int {
    if n < 0 { return n + 4294967296 }
    n
}

// A code for a message: the unsigned value, then " / " and the signed one
// when the two differ, since installers document either.
fn code_str(n: int) -> string {
    let c = u32_code(n)
    if c > 2147483647 { return str(c) + " / " + str(c - 4294967296) }
    str(c)
}

// success_codes or reboot_codes as unsigned 32-bit values. The params map
// has already checked the param is a list, not what it holds.
fn exit_codes(params: Value, key: string) -> Result[List[int], string] {
    let out: List[int] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs {
                let Some(n) = x.as_int() else { return Err("'" + key + "' must hold integer exit codes") }
                if n < -2147483648 || n > 4294967295 {
                    return Err("'" + key + "' entry " + str(n) + " is not a 32-bit exit code: write it signed (-2147483648..2147483647) or unsigned (0..4294967295)")
                }
                out.push(u32_code(n))
            }
        }
    }
    Ok(out)
}

// Run by check, so a contradiction surfaces before anything runs. 0 is
// always Success and 3010/1641 always RebootRequired; listing one in the
// other list would silently reclassify it, so that is refused too.
fn validate_codes(params: Value) -> Result[unit, string] {
    let success = exit_codes(params, "success_codes")?
    let reboot = exit_codes(params, "reboot_codes")?
    for c in success {
        if c == 3010 || c == 1641 {
            return Err("'success_codes' lists " + str(c) + ", a built-in reboot code: 3010 and 1641 always mean RebootRequired, and listing one would silently reclassify it as Success")
        }
        if reboot.contains(c) {
            return Err("exit code " + code_str(c) + " is in both 'success_codes' and 'reboot_codes'; list it in one")
        }
    }
    for c in reboot {
        if c == 0 {
            return Err("'reboot_codes' lists 0, the built-in success code: 0 always means Success, and listing it would silently reclassify every clean exit as RebootRequired")
        }
    }
    Ok(())
}

// What an installer's exit code means: "reboot" for 3010, 1641 and
// reboot_codes, "success" for 0 and success_codes, else "fail".
fn outcome(params: Value, code: int) -> Result[string, string] {
    let c = u32_code(code)
    if c == 3010 || c == 1641 || exit_codes(params, "reboot_codes")?.contains(c) { return Ok("reboot") }
    if c == 0 || exit_codes(params, "success_codes")?.contains(c) { return Ok("success") }
    Ok("fail")
}

// Splits an argument string the way an installer's command line parser
// does for this purpose: on whitespace outside double quotes, dropping the
// quotes.
fn split_args(args: string) -> List[string] {
    let out: List[string] = []
    let cur = ""
    let quoted = false
    let open = false
    for c in args.chars() {
        let s = str(c)
        if s == "\"" {
            quoted = !quoted
            open = true
        } else if !quoted && (s == " " || s == "\t") {
            if open { out.push(cur) }
            cur = ""
            open = false
        } else {
            cur = cur + s
            open = true
        }
    }
    if open { out.push(cur) }
    out
}

// msiexec's logging switch: /l or -l followed by one or more mode
// characters, e.g. /l*v, /L*VX, /lv, /l*v+.
fn is_msi_log_flag(token: string) -> bool {
    let t = token.to_lower()
    if t.len() < 3 || !(t.starts_with("/l") || t.starts_with("-l")) { return false }
    let modes = "iwearucmopvx+!*"
    for c in t.slice(2, t.len()).chars() {
        if !modes.contains(str(c)) { return false }
    }
    true
}

// The log file an argument string names, "" when none: the value after
// /log or -log (most bootstrappers: Burn, InstallShield, VS) or after an
// msiexec /l<modes> switch, case-insensitive, quoted or not.
fn log_arg(args: string) -> string {
    let toks = split_args(args)
    let i = 0
    for t in toks {
        let l = t.to_lower()
        if l == "/log" || l == "-log" || is_msi_log_flag(t) {
            return toks.get(i + 1).unwrap_or("")
        }
        i = i + 1
    }
    ""
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
