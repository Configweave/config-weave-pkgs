// Helpers the windows_sysprep scripts share: param access, XML escaping,
// and the unattend password encoding.
use value

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
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

// & must go first or the entity ampersands get double-escaped.
fn xml_esc(s: string) -> string {
    s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")
}

// UTF-16LE bytes of a string, with surrogate pairs above U+FFFF.
fn utf16le(s: string) -> List[int] {
    let out: List[int] = []
    for c in s.chars() {
        let cp = int(c)
        if cp > 65535 {
            let v = cp - 65536
            let hi = 55296 + v / 1024
            let lo = 56320 + v % 1024
            out.push(hi % 256)
            out.push(hi / 256)
            out.push(lo % 256)
            out.push(lo / 256)
        } else {
            out.push(cp % 256)
            out.push(cp / 256)
        }
    }
    out
}

// Standard base64 (RFC 4648) with padding. The host API has no encoder in
// config-weave 0.5.0-alpha (engine gap E6), hence this one.
fn base64(bytes: List[int]) -> string {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".chars()
    let out = ""
    let i = 0
    let n = bytes.len()
    while i < n {
        let b0 = bytes[i]
        let b1 = if i + 1 < n { bytes[i + 1] } else { 0 }
        let b2 = if i + 2 < n { bytes[i + 2] } else { 0 }
        let triple = b0 * 65536 + b1 * 256 + b2
        out = out + str(alphabet[triple / 262144 % 64]) + str(alphabet[triple / 4096 % 64])
        out = out + if i + 1 < n { str(alphabet[triple / 64 % 64]) } else { "=" }
        out = out + if i + 2 < n { str(alphabet[triple % 64]) } else { "=" }
        i = i + 3
    }
    out
}

// The encoding Windows SIM writes for a hidden password: base64 of the
// UTF-16LE password with the element name appended (`AdministratorPassword`,
// `Password`), marked PlainText=false.
fn hidden_password(pw: string, element: string) -> string {
    "<Value>" + base64(utf16le(pw + element)) + "</Value><PlainText>false</PlainText>"
}
