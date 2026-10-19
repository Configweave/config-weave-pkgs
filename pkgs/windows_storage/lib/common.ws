// Helpers every windows_storage script shares: params, quoting and running
// Windows PowerShell. Copied from windows_files, so each package stays
// independent when vendored alone.
use value
use fs
use path
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
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
    if let Some(v) = m.get(key) { if let Some(i) = v.as_int() { return i } }
    -1
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

// A JSON field that ConvertTo-Json may have emitted as a list, as a single
// collapsed value, or as null.
fn get_list(m: Value, key: string) -> List[Value] {
    let out: List[Value] = []
    if let Some(v) = m.get(key) {
        if let Some(items) = v.as_list() {
            for item in items { out.push(item) }
        } else if !v.is_null() {
            out.push(v)
        }
    }
    out
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

// Many tools report failures on stdout, so the error carries stderr, falls
// back to stdout, and always names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// Runs a Windows PowerShell script from a temp .ps1, so the script never
// passes through command-line quoting and may hold any character. The file
// carries a UTF-8 BOM because 5.1 reads a BOM-less script as the ANSI code
// page, and output is forced to UTF-8 because 5.1 otherwise re-encodes it
// to the OEM code page. The trap reduces a terminating error to its message.
fn run_ps(script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-storage.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\ntrap {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\""
    // Formatting a large volume takes a while; the quick format used here
    // is seconds, so ten minutes is generous.
    let out = shell::run(cmd, Value::Map(#{ "timeout": Value::Int(600) }))
    fs::delete_dir(dir)?
    out
}

fn ps_run(what: string, script: string) -> Result[unit, string] {
    let out = run_ps(script)?
    if !out.success { return Err(failure(what, out)) }
    Ok(())
}

// A script whose output is one JSON document.
fn ps_json(what: string, script: string) -> Result[Value, string] {
    let out = run_ps(script)?
    if !out.success { return Err(failure(what, out)) }
    let text = out.stdout.trim()
    if text == "" { return Err(what + " printed nothing") }
    json::parse(text)
}
