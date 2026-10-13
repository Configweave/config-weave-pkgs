// Helpers every windows_registry script shares: params, running Windows
// PowerShell, quoting, key paths and registry views.
//
// Both resources talk to the registry through .NET's RegistryKey in
// PowerShell rather than the host `registry` module: the host module cannot
// report a value's kind, cannot read REG_BINARY or REG_NONE, and cannot pick
// the 32- or 64-bit view (engine gap E1).
use value
use fs
use path
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_list(params: Value, key: string) -> List[Value] {
    let items: List[Value] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs { items.push(x) }
        }
    }
    items
}

fn param_strs(params: Value, key: string) -> List[string] {
    let items: List[string] = []
    for x in param_list(params, key) {
        if let Some(s) = x.as_string() { items.push(s) }
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

fn get_int(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(n) = v.as_int() { return n } }
    0
}

// A JSON field that ConvertTo-Json may have emitted as a list, as a single
// collapsed object, or as null.
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

fn ps_list(items: List[string]) -> string {
    let quoted: List[string] = []
    for item in items { quoted.push(ps_q(item)) }
    "@(" + quoted.join(",") + ")"
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
    let file = path::join(dir, "config-weave-registry.ps1")
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

// A script whose last line of output is one JSON document.
fn ps_json(what: string, script: string) -> Result[Value, string] {
    let out = run_ps(script)?
    if !out.success { return Err(failure(what, out)) }
    let text = out.stdout.trim()
    if text == "" { return Err(what + " printed nothing") }
    json::parse(text)
}

// ---------------------------------------------------------------------
// Key paths and views
// ---------------------------------------------------------------------

// The RegistryHive member for a hive prefix. Like the engine, any case and
// both the short and long names are accepted.
fn hive_of(prefix: string) -> Option[string] {
    let p = prefix.to_upper()
    if p == "HKLM" || p == "HKEY_LOCAL_MACHINE" { return Some("LocalMachine") }
    if p == "HKCU" || p == "HKEY_CURRENT_USER" { return Some("CurrentUser") }
    if p == "HKCR" || p == "HKEY_CLASSES_ROOT" { return Some("ClassesRoot") }
    if p == "HKU" || p == "HKEY_USERS" { return Some("Users") }
    if p == "HKCC" || p == "HKEY_CURRENT_CONFIG" { return Some("CurrentConfig") }
    None
}

// A key path → [hive member, subkey path below the hive]. Trailing
// backslashes are dropped; empty segments, "." and ".." segments, and line
// breaks are rejected. `min_depth` is how many segments must follow the
// hive.
fn split_key(key: string, min_depth: int) -> Result[List[string], string] {
    if key == "" { return Err("missing 'key' parameter") }
    if key.contains("\n") || key.contains("\r") { return Err("'key' must not contain a line break") }
    let k = key
    while k.ends_with("\\") { k = k.slice(0, k.len() - 1) }
    let parts = k.split("\\")
    let prefix = parts.get(0).unwrap_or("")
    let hive = hive_of(prefix)
    if hive.is_none() {
        return Err("'key' must start with a hive (HKLM, HKCU, HKCR, HKU or HKCC, or the HKEY_ name), got '" + key + "'")
    }
    let segs: List[string] = []
    for i in 1..parts.len() {
        let seg = parts.get(i).unwrap_or("")
        if seg == "" { return Err("'key' must not contain an empty segment (a doubled backslash), got '" + key + "'") }
        if seg == "." || seg == ".." { return Err("'key' must not contain '.' or '..' segments, got '" + key + "'") }
        segs.push(seg)
    }
    if segs.len() < min_depth {
        return Err("'key' needs at least " + str(min_depth) + " segment(s) below the hive, got '" + key + "'")
    }
    Ok([hive.unwrap_or(""), segs.join("\\")])
}

fn view_member(params: Value) -> Result[string, string] {
    let v = param_str(params, "view", "native")
    if v == "native" { return Ok("Default") }
    if v == "wow64_32" { return Ok("Registry32") }
    if v == "wow64_64" { return Ok("Registry64") }
    Err("invalid 'view' value '" + v + "' (expected :native, :wow64_32 or :wow64_64)")
}

// PowerShell that sets $base to the hive's root key in the chosen view and
// $sub to the subkey path.
fn ps_open(hive: string, view: string, sub: string) -> string {
    "$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::" + hive +
    ", [Microsoft.Win32.RegistryView]::" + view + ")\n" +
    "$sub = " + ps_q(sub) + "\n"
}
