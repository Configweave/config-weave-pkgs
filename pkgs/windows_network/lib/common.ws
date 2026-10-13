// Helpers every windows_network script shares: param access, address
// validation, quoting, and running PowerShell.
use value
use shell
use json

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

fn get_int(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(n) = v.as_int() { return n } }
    0
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

// The JSON payload as a string list whether it carried a list or a single
// collapsed string (ConvertTo-Json in Windows PowerShell 5.1).
fn str_items(v: Value) -> List[string] {
    let items: List[string] = []
    if let Some(xs) = v.as_list() {
        for x in xs {
            if let Some(s) = x.as_string() { items.push(s) }
        }
    } else if let Some(s) = v.as_string() {
        if s != "" { items.push(s) }
    }
    items
}

fn get_list(m: Value, key: string) -> List[string] {
    if let Some(v) = m.get(key) { return str_items(v) }
    []
}

// ---------------------------------------------------------------------
// Validation (check and apply both call it, so check fails loudly too)
// ---------------------------------------------------------------------

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// A value handed to a cmdlet -Name/-InterfaceAlias, where *?[] are
// wildcards: 'web*' would select (and delete) every matching rule.
fn no_wildcards(label: string, value: string) -> Result[unit, string] {
    if value == "" { return Err("missing '" + label + "' parameter") }
    for c in ["*", "?", "[", "]"] {
        if value.contains(c) { return Err("'" + label + "' must not contain the wildcard character '" + c + "', got '" + value + "'") }
    }
    single_line(label, value)
}

fn octets(addr: string) -> Option[List[int]] {
    let parts = addr.split(".")
    if parts.len() != 4 { return None }
    let out: List[int] = []
    for p in parts {
        if p == "" || p.len() > 3 { return None }
        for c in p.chars() { if c < '0' || c > '9' { return None } }
        if let Some(n) = p.parse_int() {
            if n > 255 { return None }
            out.push(n)
        } else { return None }
    }
    Some(out)
}

fn is_ipv4(addr: string) -> bool { octets(addr).is_some() }

// Hex groups and colons, at most one '::', optionally ending in an IPv4
// tail. PowerShell parses it again before anything is changed.
fn is_ipv6(addr: string) -> bool {
    if !addr.contains(":") || addr.len() > 45 { return false }
    for c in addr.chars() {
        let ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == ':' || c == '.'
        if !ok { return false }
    }
    addr.split("::").len() <= 2
}

// "IPv4" or "IPv6" for an address, or an error naming the param.
fn family_of(label: string, addr: string) -> Result[string, string] {
    if is_ipv4(addr) { return Ok("IPv4") }
    if is_ipv6(addr) { return Ok("IPv6") }
    Err("'" + label + "' is not an IPv4 or IPv6 address, got '" + addr + "'")
}

// ---------------------------------------------------------------------
// Quoting and PowerShell
// ---------------------------------------------------------------------

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

// The error carries stderr, falls back to stdout, and names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// Run `script`. A failure is reported as its message alone, without the
// source line PowerShell 5.1 prints after it.
// Success exits 0 explicitly: the exit code would otherwise follow $? of
// the last statement, which a deliberately caught not-found leaves false.
fn ps(what: string, script: string) -> Result[string, string] {
    let full = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; " +
        "try {{ " + script + "\nexit 0 }} catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}"
    let out = shell::powershell(full, Value::Null)?
    if !out.success { return Err(failure(what, out)) }
    Ok(out.stdout.trim())
}

// PowerShell binding $ifx to the interface's index, failing clearly when no
// interface has that alias.
fn iface_ps(iface: string) -> string {
    "$ifo = @(Get-NetIPInterface -InterfaceAlias " + ps_q(iface) + " -ErrorAction SilentlyContinue); " +
    "if ($ifo.Count -eq 0) {{ throw ('no network interface is named ' + " + ps_q(iface) + ") }}; " +
    "$ifx = $ifo[0].InterfaceIndex; "
}

fn parse(text: string) -> Result[Value, string] { json::parse(text) }
