use value
use log
use common

// The .NET RegistryValueKind member for a `kind` symbol.
fn kind_member(kind: string) -> Result[string, string] {
    if kind == "sz" { return Ok("String") }
    if kind == "expand_sz" { return Ok("ExpandString") }
    if kind == "dword" { return Ok("DWord") }
    if kind == "qword" { return Ok("QWord") }
    if kind == "multi_sz" { return Ok("MultiString") }
    if kind == "binary" { return Ok("Binary") }
    Err("invalid 'kind' value '" + kind + "' (expected :sz, :expand_sz, :dword, :qword, :multi_sz or :binary)")
}

// "" and "(Default)" both name the key's default (unnamed) value.
fn value_name(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    if name.to_lower() == "(default)" { return Ok("") }
    if name.contains("\n") || name.contains("\r") { return Err("'name' must not contain a line break") }
    Ok(name)
}

fn display(key: string, name: string) -> string {
    let k = key
    while k.ends_with("\\") { k = k.slice(0, k.len() - 1) }
    if name == "" { return k + "\\(Default)" }
    k + "\\" + name
}

fn digits_only(s: string) -> bool {
    if s == "" { return false }
    s.chars().all(|c| c >= '0' && c <= '9')
}

fn strip_zeros(s: string) -> string {
    let out = s
    while out.len() > 1 && out.starts_with("0") { out = out.slice(1, out.len()) }
    out
}

// Decimal a <= b for digit strings without leading zeros.
fn dec_le(a: string, b: string) -> bool {
    if a.len() != b.len() { return a.len() < b.len() }
    let digits = "0123456789"
    for i in 0..a.len() {
        let da = digits.find(a.slice(i, i + 1)).unwrap_or(0)
        let db = digits.find(b.slice(i, i + 1)).unwrap_or(0)
        if da != db { return da < db }
    }
    true
}

// a - b for digit strings with a >= b.
fn dec_sub(a: string, b: string) -> string {
    let digits = "0123456789"
    let out: List[string] = []
    let borrow = 0
    let i = a.len() - 1
    let j = b.len() - 1
    while i >= 0 {
        let da = digits.find(a.slice(i, i + 1)).unwrap_or(0)
        let db = if j >= 0 { digits.find(b.slice(j, j + 1)).unwrap_or(0) } else { 0 }
        let d = da - db - borrow
        if d < 0 {
            d = d + 10
            borrow = 1
        } else {
            borrow = 0
        }
        out.insert(0, str(d))
        i = i - 1
        j = j - 1
    }
    strip_zeros(out.join(""))
}

// A DWORD or QWORD written as decimal → its unsigned decimal form, which is
// how the probe reports it. Negative numbers are the signed spelling of the
// same bits: "-1" is 4294967295 as a DWORD.
fn number_canon(data: string, kind: string) -> Result[string, string] {
    let t = data.trim()
    let bits_max = if kind == "dword" { "4294967295" } else { "18446744073709551615" }
    let wrap = if kind == "dword" { "4294967296" } else { "18446744073709551616" }
    let neg_min = if kind == "dword" { "2147483648" } else { "9223372036854775808" }
    let range = if kind == "dword" { "-2147483648..4294967295" } else { "-9223372036854775808..18446744073709551615" }
    let bad = "'data' must be a decimal integer in " + range + " for " + kind + ", got '" + data + "'"
    if t.starts_with("-") {
        let mag = t.slice(1, t.len())
        if !digits_only(mag) { return Err(bad) }
        let m = strip_zeros(mag)
        if m == "0" { return Ok("0") }
        if !dec_le(m, neg_min) { return Err(bad) }
        return Ok(dec_sub(wrap, m))
    }
    if !digits_only(t) { return Err(bad) }
    let m = strip_zeros(t)
    if !dec_le(m, bits_max) { return Err(bad) }
    Ok(m)
}

// Hex text (separators ' ', ',', '-' and ':' ignored) → lower-case hex.
fn hex_canon(data: string) -> Result[string, string] {
    let hex = "0123456789abcdef"
    let out = ""
    for c in data.to_lower().chars() {
        let s = str(c)
        if s == " " || s == "," || s == "-" || s == ":" { continue }
        if hex.find(s).is_none() { return Err("'data' for binary must be hex digits, got '" + data + "'") }
        out = out + s
    }
    if out.len() % 2 != 0 { return Err("'data' for binary must hold whole bytes (an even number of hex digits), got '" + data + "'") }
    Ok(out)
}

fn byte_hex(n: int) -> string {
    let hex = "0123456789abcdef"
    hex.slice(n / 16, n / 16 + 1) + hex.slice(n % 16, n % 16 + 1)
}

// The wanted data in the same canonical shape the probe reports: a string
// for sz/expand_sz, unsigned decimal for dword/qword, a list of strings for
// multi_sz and lower-case hex for binary.
fn desired(params: Value, kind: string) -> Result[Value, string] {
    let data = common::param_str(params, "data", "")
    let items = common::param_list(params, "data_list")
    if kind == "sz" || kind == "expand_sz" || kind == "dword" || kind == "qword" {
        if !items.is_empty() { return Err("'data_list' is only used by kind :multi_sz and :binary; use 'data' for " + kind) }
    }
    if kind == "sz" || kind == "expand_sz" { return Ok(Value::String(data)) }
    if kind == "dword" || kind == "qword" { return Ok(Value::String(number_canon(data, kind)?)) }
    if kind == "multi_sz" {
        if data != "" { return Err("kind :multi_sz takes its strings in 'data_list', not 'data'") }
        let out: List[Value] = []
        for item in items {
            if let Some(s) = item.as_string() {
                if s == "" { return Err("a :multi_sz value cannot hold an empty string (REG_MULTI_SZ ends at the first empty entry)") }
                out.push(Value::String(s))
            } else {
                return Err("'data_list' for :multi_sz must hold strings")
            }
        }
        return Ok(Value::List(out))
    }
    if kind == "binary" {
        if items.is_empty() { return Ok(Value::String(hex_canon(data)?)) }
        if data != "" { return Err("set either 'data' (hex) or 'data_list' (byte ints) for :binary, not both") }
        let out = ""
        for item in items {
            let n = item.as_int().unwrap_or(-1)
            if n < 0 || n > 255 { return Err("'data_list' for :binary must hold ints 0..255") }
            out = out + byte_hex(n)
        }
        return Ok(Value::String(out))
    }
    kind_member(kind)?
    Err("unreachable")
}

// PowerShell for the .NET object SetValue stores for the canonical data.
fn ps_data(kind: string, want: Value) -> string {
    if kind == "dword" {
        return "[BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]" + common::ps_q(want.as_string().unwrap_or("0")) + "), 0)"
    }
    if kind == "qword" {
        return "[BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]" + common::ps_q(want.as_string().unwrap_or("0")) + "), 0)"
    }
    if kind == "multi_sz" {
        let items: List[string] = []
        for v in want.as_list().unwrap_or([]) { items.push(v.as_string().unwrap_or("")) }
        return "[string[]]" + common::ps_list(items)
    }
    if kind == "binary" {
        let hex = want.as_string().unwrap_or("")
        let bytes: List[string] = []
        let i = 0
        while i < hex.len() {
            bytes.push("0x" + hex.slice(i, i + 2))
            i = i + 2
        }
        return "[byte[]]@(" + bytes.join(",") + ")"
    }
    common::ps_q(want.as_string().unwrap_or(""))
}

// { key: bool, exists: bool, kind, data } for one value. Data is reported
// raw (no environment expansion), numbers as unsigned decimal strings and
// bytes as lower-case hex.
fn probe(hive: string, view: string, sub: string, name: string) -> Result[Value, string] {
    common::ps_json("reading registry value",
        common::ps_open(hive, view, sub) +
        "$name = " + common::ps_q(name) + "\n" +
        "$k = $base.OpenSubKey($sub, $false)\n" +
        "if ($null -eq $k) {{ '{{\"key\":false,\"exists\":false}}'; exit 0 }}\n" +
        "if (-not (@($k.GetValueNames()) -contains $name)) {{ '{{\"key\":true,\"exists\":false}}'; exit 0 }}\n" +
        "$kind = $k.GetValueKind($name).ToString()\n" +
        "$v = $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames')\n" +
        "switch ($kind) {{\n" +
        "  'DWord' {{ $d = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$v), 0).ToString() }}\n" +
        "  'QWord' {{ $d = [BitConverter]::ToUInt64([BitConverter]::GetBytes([int64]$v), 0).ToString() }}\n" +
        "  'MultiString' {{ $d = @($v) }}\n" +
        "  'Binary' {{ $d = ([BitConverter]::ToString([byte[]]$v)).Replace('-', '').ToLower() }}\n" +
        "  'None' {{ $d = $null }}\n" +
        "  'Unknown' {{ $d = $null }}\n" +
        "  default {{ $d = [string]$v }}\n" +
        "}}\n" +
        "[pscustomobject]@{{ key = $true; exists = $true; kind = $kind; data = $d }} | ConvertTo-Json -Compress -Depth 4\n"
    )
}

fn data_matches(kind: string, have: Value, want: Value) -> bool {
    if kind == "multi_sz" {
        let h = common::get_list(have, "data")
        let w = want.as_list().unwrap_or([])
        if h.len() != w.len() { return false }
        for i in 0..h.len() {
            if h.get(i).unwrap_or(Value::Null).as_string().unwrap_or("") != w.get(i).unwrap_or(Value::Null).as_string().unwrap_or("") { return false }
        }
        return true
    }
    common::get_str(have, "data") == want.as_string().unwrap_or("")
}

// [key as written, hive member, subkey path, view member, value name].
fn target(params: Value) -> Result[List[string], string] {
    let key = common::param_str(params, "key", "")
    let parts = common::split_key(key, 1)?
    Ok([key, parts.get(0).unwrap_or(""), parts.get(1).unwrap_or(""), common::view_member(params)?, value_name(params)?])
}

fn check(params: Value) -> Result[CheckResult, string] {
    let t = target(params)?
    let key = t.get(0).unwrap_or("")
    let hive = t.get(1).unwrap_or("")
    let sub = t.get(2).unwrap_or("")
    let view = t.get(3).unwrap_or("")
    let name = t.get(4).unwrap_or("")
    let present = common::want_present(params)?
    let kind = common::param_str(params, "kind", "sz")
    let ps_kind = kind_member(kind)?
    let want = if present { desired(params, kind)? } else { Value::Null }
    let have = probe(hive, view, sub, name)?
    let exists = common::get_bool(have, "exists")
    if !present {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !exists { return Ok(CheckResult::NotConfigured) }
    if common::get_str(have, "kind") != ps_kind { return Ok(CheckResult::NotConfigured) }
    if !data_matches(kind, have, want) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let t = target(params)?
    let key = t.get(0).unwrap_or("")
    let hive = t.get(1).unwrap_or("")
    let sub = t.get(2).unwrap_or("")
    let view = t.get(3).unwrap_or("")
    let name = t.get(4).unwrap_or("")
    let open = common::ps_open(hive, view, sub) + "$name = " + common::ps_q(name) + "\n"
    if !common::want_present(params)? {
        // DeleteValue works on every kind, binary included, so the value is
        // never read first.
        log::info("deleting registry value " + display(key, name))
        common::ps_run("deleting registry value " + display(key, name),
            open +
            "$k = $base.OpenSubKey($sub, $true)\n" +
            "if ($null -ne $k) {{ $k.DeleteValue($name, $false) }}\n"
        )?
        return Ok(ApplyResult::Success)
    }
    let kind = common::param_str(params, "kind", "sz")
    let ps_kind = kind_member(kind)?
    let want = desired(params, kind)?
    log::info("writing registry value " + display(key, name))
    // SetValue replaces both the data and the kind of an existing value.
    common::ps_run("writing registry value " + display(key, name),
        open +
        "$k = $base.CreateSubKey($sub)\n" +
        "$k.SetValue($name, " + ps_data(kind, want) + ", [Microsoft.Win32.RegistryValueKind]::" + ps_kind + ")\n"
    )?
    Ok(ApplyResult::Success)
}
