use value
use log
use registry
use common

fn check_kind(kind: string) -> Result[unit, string] {
    for k in ["sz", "expand_sz", "dword", "qword", "multi_sz", "binary"] {
        if kind == k { return Ok(()) }
    }
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

// A DWORD or QWORD written as decimal → its unsigned decimal form.
// Negative numbers are the signed spelling of the
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

// The int the host module stores for a canonical (unsigned decimal) number,
// and reads back. A DWORD is its unsigned value; a QWORD is its 64 bits as a
// signed int, so one above 9223372036854775807 becomes the negative number
// with the same bits (18446744073709551615 is -1).
fn number_int(canon: string, kind: string) -> Result[int, string] {
    let text = if kind == "qword" && !dec_le(canon, "9223372036854775807") {
        "-" + dec_sub("18446744073709551616", canon)
    } else {
        canon
    }
    match text.parse_int() {
        Some(n) => Ok(n),
        None => Err("cannot represent '" + canon + "' as a " + kind)
    }
}

fn hex_digit(s: string) -> int {
    "0123456789abcdef".find(s).unwrap_or(0)
}

// Hex text (separators ' ', ',', '-' and ':' ignored) → byte ints.
fn hex_bytes(data: string) -> Result[List[Value], string] {
    let hex = "0123456789abcdef"
    let digits = ""
    for c in data.to_lower().chars() {
        let s = str(c)
        if s == " " || s == "," || s == "-" || s == ":" { continue }
        if hex.find(s).is_none() { return Err("'data' for binary must be hex digits, got '" + data + "'") }
        digits = digits + s
    }
    if digits.len() % 2 != 0 { return Err("'data' for binary must hold whole bytes (an even number of hex digits), got '" + data + "'") }
    let out: List[Value] = []
    let i = 0
    while i < digits.len() {
        out.push(Value::Int(hex_digit(digits.slice(i, i + 1)) * 16 + hex_digit(digits.slice(i + 1, i + 2))))
        i = i + 2
    }
    Ok(out)
}

// The wanted data in the shape the host module writes and `read_typed`
// returns: a string for sz/expand_sz, an int for dword/qword, a list of
// strings for multi_sz and a list of byte ints for binary.
fn desired(params: Value, kind: string) -> Result[Value, string] {
    check_kind(kind)?
    let data = common::param_str(params, "data", "")
    let items = common::param_list(params, "data_list")
    if kind == "sz" || kind == "expand_sz" || kind == "dword" || kind == "qword" {
        if !items.is_empty() { return Err("'data_list' is only used by kind :multi_sz and :binary; use 'data' for " + kind) }
    }
    if kind == "sz" || kind == "expand_sz" { return Ok(Value::String(data)) }
    if kind == "dword" || kind == "qword" { return Ok(Value::Int(number_int(number_canon(data, kind)?, kind)?)) }
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
    // binary
    if items.is_empty() { return Ok(Value::List(hex_bytes(data)?)) }
    if data != "" { return Err("set either 'data' (hex) or 'data_list' (byte ints) for :binary, not both") }
    let out: List[Value] = []
    for item in items {
        let n = item.as_int().unwrap_or(-1)
        if n < 0 || n > 255 { return Err("'data_list' for :binary must hold ints 0..255") }
        out.push(Value::Int(n))
    }
    Ok(Value::List(out))
}

fn data_matches(kind: string, have: Value, want: Value) -> bool {
    if kind == "multi_sz" || kind == "binary" {
        let h = have.as_list().unwrap_or([])
        let w = want.as_list().unwrap_or([])
        if h.len() != w.len() { return false }
        for i in 0..h.len() {
            let a = h.get(i).unwrap_or(Value::Null)
            let b = w.get(i).unwrap_or(Value::Null)
            if kind == "binary" {
                if a.as_int().unwrap_or(-1) != b.as_int().unwrap_or(-2) { return false }
            } else if a.as_string().unwrap_or("") != b.as_string().unwrap_or("") {
                return false
            }
        }
        return true
    }
    if kind == "dword" || kind == "qword" {
        if let Some(n) = have.as_int() { return n == want.as_int().unwrap_or(0) }
        return false
    }
    if let Some(s) = have.as_string() { return s == want.as_string().unwrap_or("") }
    false
}

// [key as written, key for the host module, value name].
fn target(params: Value) -> Result[List[string], string] {
    let key = common::param_str(params, "key", "")
    let parts = common::split_key(key, 1)?
    Ok([key, common::host_key(parts.get(0).unwrap_or(""), parts.get(1).unwrap_or("")), value_name(params)?])
}

// The value as `{kind, data}`, or None when it or its key is absent. A value
// of a kind the host module cannot decode (REG_LINK, REG_RESOURCE_LIST, ...)
// is reported with kind "unsupported", so it counts as drift rather than an
// error and :absent can still delete it.
fn read(hkey: string, name: string, opts: Value) -> Option[Value] {
    match registry::read_typed(hkey, name, opts) {
        Ok(v) => v,
        Err(e) => {
            log::info("reading " + hkey + "\\" + name + ": " + e)
            Some(Value::Map(#{ "kind": Value::String("unsupported"), "data": Value::Null }))
        }
    }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let t = target(params)?
    let hkey = t.get(1).unwrap_or("")
    let name = t.get(2).unwrap_or("")
    let opts = common::view_opts(params)?
    let present = common::want_present(params)?
    let kind = common::param_str(params, "kind", "sz")
    let want = if present { desired(params, kind)? } else { Value::Null }
    let have = read(hkey, name, opts)
    if !present {
        if have.is_some() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let Some(h) = have else { return Ok(CheckResult::NotConfigured) }
    if common::get_str(h, "kind") != kind { return Ok(CheckResult::NotConfigured) }
    if !data_matches(kind, h.get("data").unwrap_or(Value::Null), want) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let t = target(params)?
    let key = t.get(0).unwrap_or("")
    let hkey = t.get(1).unwrap_or("")
    let name = t.get(2).unwrap_or("")
    let opts = common::view_opts(params)?
    if !common::want_present(params)? {
        // delete_value works on every kind, binary included, so the value is
        // never read first. It fails on a missing key, which needs no delete.
        if !registry::key_exists_with(hkey, opts)? { return Ok(ApplyResult::Success) }
        log::info("deleting registry value " + display(key, name))
        registry::delete_value_with(hkey, name, opts)?
        return Ok(ApplyResult::Success)
    }
    let kind = common::param_str(params, "kind", "sz")
    let want = desired(params, kind)?
    log::info("writing registry value " + display(key, name))
    // write_with creates the key when missing and replaces both the data and
    // the kind of an existing value.
    registry::write_with(hkey, name, want, kind, opts)?
    Ok(ApplyResult::Success)
}
