// Helpers every vsix script shares: params, running PowerShell, fetching
// a VSIX and reading its manifest.
use value
use fs
use path
use shell
use json
use http
use hash
use time
use env
use log

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

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

// A JSON field that may be a list, a single collapsed value, or null.
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

// Tools report failures on either stream or only through the exit code,
// so the error carries stderr, falls back to stdout, and always names the
// exit code.
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
// drops output that is not valid UTF-8. The trap reduces a terminating
// error to its message.
fn run_ps(script: string, env: Map[string, Value], timeout: int) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-vsix.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\ntrap {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\""
    let out = shell::run(cmd, Value::Map(#{ "env": Value::Map(env), "timeout": Value::Int(timeout) }))
    fs::delete_dir(dir)?
    out
}

// A script whose output is one JSON document.
fn ps_json(what: string, script: string, env: Map[string, Value]) -> Result[Value, string] {
    let out = run_ps(script, env, 600)?
    if !out.success { return Err(failure(what, out)) }
    let text = out.stdout.trim()
    if text == "" { return Err(what + " printed nothing") }
    json::parse(text)
}

// ---------------------------------------------------------------------
// Validation (run by both check and apply)
// ---------------------------------------------------------------------

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// A value that reaches a command line inside double quotes, or a .cmd
// file's arguments: no double quote and none of cmd.exe's metacharacters.
fn cmd_safe(label: string, value: string) -> Result[unit, string] {
    single_line(label, value)?
    for c in ["\"", "%", "&", "|", "<", ">", "^"] {
        if value.contains(c) { return Err("'" + label + "' must not contain " + c + ", got '" + value + "'") }
    }
    Ok(())
}

// An extension id or version: letters, digits, '.', '-', '_' and '+', not
// starting with '-'.
fn validate_token(label: string, value: string) -> Result[unit, string] {
    let allowed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_+"
    if value.starts_with("-") || !value.chars().all(|c| allowed.contains(str(c))) {
        return Err("'" + label + "' may only hold letters, digits, '.', '-', '_' and '+', got '" + value + "'")
    }
    Ok(())
}

fn is_hex(s: string) -> bool {
    s.chars().all(|c| (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
}

fn validate_sha256(value: string) -> Result[unit, string] {
    if value == "" { return Ok(()) }
    if value.len() != 64 || !is_hex(value) { return Err("'sha256' must be 64 hex digits, got '" + value + "'") }
    Ok(())
}

// Versions compare with trailing ".0" groups dropped, as the VSIX engine
// compares them: 2.9.18 is 2.9.18.0.
fn norm_version(v: string) -> string {
    let out = v.trim().to_lower()
    while out.ends_with(".0") && out.split(".").len() > 2 { out = out.slice(0, out.len() - 2) }
    out
}

fn same_version(a: string, b: string) -> bool { norm_version(a) == norm_version(b) }

// Lower-cased, backslash-separated and without a trailing separator, for
// comparing paths the way NTFS does.
fn norm_path(p: string) -> string {
    let out = p.replace("/", "\\").to_lower().trim()
    while out.len() > 3 && out.ends_with("\\") { out = out.slice(0, out.len() - 1) }
    out
}

// ---------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------

fn is_url(src: string) -> bool {
    let l = src.to_lower()
    l.starts_with("http://") || l.starts_with("https://")
}

// A Marketplace item name ("publisher.name") rather than a path or URL:
// no separators, no drive colon, not a .vsix file name.
fn is_marketplace_name(src: string) -> bool {
    if src == "" || is_url(src) { return false }
    if src.contains("\\") || src.contains("/") || src.contains(":") { return false }
    if src.to_lower().ends_with(".vsix") { return false }
    src.contains(".")
}

// Downloads are kept under ProgramData, one directory per source.
fn cache_dir() -> string {
    let pd = env::get("ProgramData").unwrap_or("C:\\ProgramData")
    path::join(pd, "config-weave\\vsix")
}

fn file_size(p: string) -> int {
    if let Ok(m) = fs::metadata(p) {
        if let Some(v) = m.get("size") { return v.as_int().unwrap_or(-1) }
    }
    -1
}

// Downloads `url` to `dest`. The file goes to a .part name beside it,
// retried up to three times, and must have the length the transfer
// reported (and `sha256` when set) before it is moved into place, so a
// failed or partial download is never used.
fn download(url: string, dest: string, sha256: string) -> Result[unit, string] {
    fs::mkdir(path::parent(dest))?
    let part = dest + ".part"
    let last = ""
    let attempt = 1
    while attempt <= 3 {
        if fs::exists(part) { fs::delete(part)? }
        log::info("downloading " + url + " (attempt " + str(attempt) + ")")
        match http::download(url, part, Value::Map(#{ "timeout": Value::Int(1800) })) {
            Ok(n) => {
                let size = file_size(part)
                if n <= 0 || size != n {
                    last = "got " + str(size) + " bytes on disk of " + str(n) + " downloaded"
                } else if sha256 != "" && hash::sha256_file(part)?.to_lower() != sha256.to_lower() {
                    last = "SHA-256 is " + hash::sha256_file(part)? + ", expected " + sha256.to_lower()
                } else {
                    if fs::exists(dest) { fs::delete(dest)? }
                    fs::move(part, dest)?
                    return Ok(())
                }
            }
            Err(e) => { last = e }
        }
        attempt = attempt + 1
        if attempt <= 3 { time::sleep(5000) }
    }
    if fs::exists(part) { fs::delete(part).unwrap_or(()) }
    Err("downloading " + url + " failed after 3 attempts: " + last)
}

// A local copy of a URL source, reusing the cached copy when it still
// matches `sha256`.
fn fetch(url: string, sha256: string, name: string) -> Result[string, string] {
    let dest = path::join(path::join(cache_dir(), hash::sha256(url).slice(0, 16)), name)
    if sha256 != "" && fs::is_file(dest) && hash::sha256_file(dest)?.to_lower() == sha256.to_lower() { return Ok(dest) }
    download(url, dest, sha256)?
    Ok(dest)
}

fn local_source(src: string, sha256: string) -> Result[string, string] {
    if !fs::is_file(src) { return Err("VSIX file '" + src + "' does not exist") }
    if sha256 != "" && hash::sha256_file(src)?.to_lower() != sha256.to_lower() {
        return Err("'" + src + "' has SHA-256 " + hash::sha256_file(src)? + ", expected " + sha256.to_lower())
    }
    Ok(src)
}

// ---------------------------------------------------------------------
// VSIX manifests
// ---------------------------------------------------------------------

// PowerShell function: the [Id, Version, Publisher] of an extension.vsixmanifest
// document, for both the 2011 schema (PackageManifest/Metadata/Identity)
// and the 2010 one (Vsix/Identifier with a Version child).
fn manifest_identity_ps() -> string {
    "function Get-VsixIdentity([xml]$x) {{\n" +
    "  $ns = New-Object Xml.XmlNamespaceManager $x.NameTable\n" +
    "  $ns.AddNamespace('a', 'http://schemas.microsoft.com/developer/vsx-schema/2011')\n" +
    "  $ns.AddNamespace('b', 'http://schemas.microsoft.com/developer/vsx-schema/2010')\n" +
    "  $i = $x.SelectSingleNode('/a:PackageManifest/a:Metadata/a:Identity', $ns)\n" +
    "  if ($i) {{ return @([string]$i.GetAttribute('Id'), [string]$i.GetAttribute('Version'), [string]$i.GetAttribute('Publisher')) }}\n" +
    "  $i = $x.SelectSingleNode('/b:Vsix/b:Identifier', $ns)\n" +
    "  if ($i) {{ $v = $i.SelectSingleNode('b:Version', $ns); return @([string]$i.GetAttribute('Id'), $(if ($v) {{ [string]$v.InnerText }} else {{ '' }}), '') }}\n" +
    "  return @('', '', '')\n" +
    "}}\n"
}

// The Identity [Id, Version, Publisher] inside a .vsix file.
fn vsix_identity(file: string) -> Result[List[string], string] {
    let script = manifest_identity_ps() +
        "Add-Type -AssemblyName System.IO.Compression.FileSystem\n" +
        "$z = [IO.Compression.ZipFile]::OpenRead($env:CW_FILE)\n" +
        "try {{\n" +
        "  $e = $z.Entries | Where-Object {{ $_.FullName -ieq 'extension.vsixmanifest' }} | Select-Object -First 1\n" +
        "  if (-not $e) {{ throw ($env:CW_FILE + ' is not a VSIX: it has no extension.vsixmanifest') }}\n" +
        "  $r = New-Object IO.StreamReader($e.Open())\n" +
        "  try {{ $idv = Get-VsixIdentity $r.ReadToEnd() }} finally {{ $r.Dispose() }}\n" +
        "}} finally {{ $z.Dispose() }}\n" +
        "ConvertTo-Json -Compress -InputObject @{{ id = $idv[0]; version = $idv[1]; publisher = $idv[2] }}\n"
    let m = ps_json("reading the manifest of " + file, script, #{ "CW_FILE": Value::String(file) })?
    Ok([get_str(m, "id"), get_str(m, "version"), get_str(m, "publisher")])
}
