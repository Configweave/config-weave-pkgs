use value
use fs

// Helpers shared by linux_pacman's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// Resolve the AUR helper: an explicit yay/paru is taken as-is; "auto"
// looks for yay then paru in /usr/bin and /bin.
fn helper(params: Value) -> Result[string, string] {
    let h = param_str(params, "helper", "auto")
    if h == "yay" || h == "paru" { return Ok(h) }
    if h != "auto" { return Err("invalid 'helper' value '" + h + "' (expected auto, yay or paru)") }
    if fs::exists("/usr/bin/yay") || fs::exists("/bin/yay") { return Ok("yay") }
    if fs::exists("/usr/bin/paru") || fs::exists("/bin/paru") { return Ok("paru") }
    Err("no AUR helper found (looked for yay and paru in /usr/bin and /bin)")
}
