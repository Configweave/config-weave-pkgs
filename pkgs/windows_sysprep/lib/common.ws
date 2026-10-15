// Helpers the windows_sysprep scripts share: param access, XML escaping,
// and the unattend password encoding.
use value
use encoding

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

// The encoding Windows SIM writes for a hidden password: base64 of the
// UTF-16LE password with the element name appended (`AdministratorPassword`,
// `Password`), marked PlainText=false.
fn hidden_password(pw: string, element: string) -> Result[string, string] {
    let v = encoding::base64_encode(encoding::utf16le(pw + element))?
    Ok("<Value>" + v + "</Value><PlainText>false</PlainText>")
}
