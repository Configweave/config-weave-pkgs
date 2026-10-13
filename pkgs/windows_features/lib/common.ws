// Helpers every windows_features script shares: param access, running
// PowerShell, and input validation.
use value
use fs
use path
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

// DISM and ServerManager errors can land on either stream, so the error
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
// drops output that is not valid UTF-8. Installs that pull payload from
// Windows Update can take many minutes, so the timeout is an hour.
fn run_ps(script: string, env: Map[string, Value]) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-features.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\""
    let out = shell::run(cmd, Value::Map(#{ "env": Value::Map(env), "timeout": Value::Int(3600) }))
    fs::delete_dir(dir)?
    out
}

// Feature, capability and role names are matched with wildcard-aware
// cmdlets, so a '*' or '?' would let one step stand for many features.
fn validate_name(name: string) -> Result[unit, string] {
    if name == "" { return Err("missing 'name' parameter") }
    for c in ["*", "?", "[", "]"] {
        if name.contains(c) { return Err("'name' must be one exact name, not a wildcard pattern ('" + c + "' in '" + name + "')") }
    }
    single_line("name", name)
}

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}
