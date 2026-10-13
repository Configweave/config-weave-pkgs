// Helpers every windows_service script shares: param access, quoting,
// running PowerShell, and input validation.
use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
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

// Many tools (sc.exe above all) report failures on stdout, so the error
// carries stderr, falls back to stdout, and always names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// Runs a script from a temp .ps1 with -File, so the script may hold any
// quote character and never appears on a command line. Values that came
// from params travel in `env` (read as $env:CW_…), which keeps secrets out
// of both the command line and the script body.
//
// The file carries a UTF-8 BOM, since Windows PowerShell 5.1 reads a
// BOM-less script as the ANSI code page. Output is forced to UTF-8 because
// 5.1 otherwise re-encodes native output to the OEM code page, and the host
// drops output that is not valid UTF-8.
fn run_ps(script: string, env: Map[string, Value]) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-service.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\""
    let out = shell::run(cmd, Value::Map(#{ "env": Value::Map(env), "timeout": Value::Int(600) }))
    fs::delete_dir(dir)?
    out
}

// A service name is an SCM key and a registry key name: no separators, no
// wildcards, nothing that would break a line.
fn validate_name(name: string) -> Result[unit, string] {
    if name == "" { return Err("missing 'name' parameter") }
    for c in ["/", "\\", "*", "?", "[", "]", "\n", "\r"] {
        if name.contains(c) { return Err("'name' must not contain '" + c.replace("\n", "\\n").replace("\r", "\\r") + "', got '" + name + "'") }
    }
    if name.starts_with(".") { return Err("'name' must not start with '.', got '" + name + "'") }
    Ok(())
}

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}
