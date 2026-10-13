// Helpers every windows_files script shares: params, running Windows
// PowerShell, quoting, path validation and content normalisation.
use value
use fs
use path
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn param_strs(params: Value, key: string) -> List[string] {
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

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
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
// to the OEM code page and the host drops output that is not valid UTF-8
// (engine gap E3). The trap reduces a terminating error to its message.
fn run_ps(script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-files.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\ntrap {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\""
    let out = shell::run(cmd, Value::Map(#{ "timeout": Value::Int(300) }))
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

// ---------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------

fn is_letter(c: string) -> bool {
    "abcdefghijklmnopqrstuvwxyz".contains(c.to_lower()) && c.len() == 1
}

// An absolute Windows path: a drive path (C:\...) or a UNC path
// (\\server\share\...), with no "." or ".." segments and no line break.
// Forward slashes are accepted as separators. Checked by check() and
// apply() alike.
fn require_path(label: string, p: string) -> Result[unit, string] {
    if p == "" { return Err("missing '" + label + "' parameter") }
    if p.contains("\n") || p.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    let drive = p.len() >= 3 && is_letter(p.slice(0, 1)) && p.slice(1, 2) == ":" && (p.slice(2, 3) == "\\" || p.slice(2, 3) == "/")
    let unc = p.starts_with("\\\\")
    if !drive && !unc {
        return Err("'" + label + "' must be an absolute Windows path such as C:\\dir\\file or \\\\server\\share\\file, got '" + p + "'")
    }
    for seg in p.replace("/", "\\").split("\\") {
        if seg == "." || seg == ".." { return Err("'" + label + "' must not contain '.' or '..' segments, got '" + p + "'") }
    }
    Ok(())
}

// Lower-cased, backslash-separated, without trailing separators (a drive
// root keeps its backslash), for comparing paths the way NTFS does.
fn norm_path(p: string) -> string {
    let out = p.replace("/", "\\").to_lower()
    while out.len() > 3 && out.ends_with("\\") { out = out.slice(0, out.len() - 1) }
    out
}

// ---------------------------------------------------------------------
// Content
// ---------------------------------------------------------------------

// The line_endings param applied to wanted content: :preserve leaves it as
// written, :crlf and :lf rewrite every line break.
fn with_line_endings(params: Value, content: string) -> Result[string, string] {
    let mode = param_str(params, "line_endings", "preserve")
    if mode == "preserve" { return Ok(content) }
    let lf = content.replace("\r\n", "\n")
    if mode == "lf" { return Ok(lf) }
    if mode == "crlf" { return Ok(lf.replace("\n", "\r\n")) }
    Err("invalid 'line_endings' value '" + mode + "' (expected :preserve, :crlf or :lf)")
}

// Whether the file holds exactly `want`. A file that is not valid UTF-8
// (UTF-16 from Notepad or PowerShell 5.1's Out-File, say) cannot equal it,
// so it is drift rather than an error.
fn content_is(p: string, want: string) -> bool {
    if let Ok(have) = fs::read(p) { return have == want }
    false
}

// Writes in place rather than through a temp file and rename: a renamed
// file would carry the temp file's security descriptor and lose any
// explicit rules on the target.
fn write_content(p: string, content: string) -> Result[unit, string] {
    if fs::is_dir(p) { return Err("'" + p + "' is a directory, not a file") }
    fs::mkdir(path::parent(p))?
    fs::write(p, content)
}
