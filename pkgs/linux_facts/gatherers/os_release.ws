use value
use fs
use sys

// os-release(5) values use shell quoting: double quotes with \" \\ \$ \`
// escapes, single quotes taken literally, or a bare word.
fn unquote(s: string) -> string {
    let t = s.trim()
    if t.len() >= 2 && t.starts_with("'") && t.ends_with("'") { return t.slice(1, t.len() - 1) }
    if t.len() >= 2 && t.starts_with("\"") && t.ends_with("\"") {
        let inner = t.slice(1, t.len() - 1)
        let out = ""
        let esc = false
        for c in inner.chars() {
            if esc {
                if c != '"' && c != '\\' && c != '$' && c != '`' { out = out + "\\" }
                out = out + str(c)
                esc = false
            } else if c == '\\' {
                esc = true
            } else {
                out = out + str(c)
            }
        }
        if esc { out = out + "\\" }
        return out
    }
    t
}

fn os_field(text: string, key: string) -> string {
    let prefix = key + "="
    for line in text.split("\n") {
        if line.starts_with(prefix) {
            return unquote(line.slice(prefix.len(), line.len()))
        }
    }
    ""
}

// /etc/os-release wins; /usr/lib/os-release is the vendor copy it usually
// links to, and the documented fallback when it is missing.
fn os_release_text() -> Result[string, string] {
    if fs::is_file("/etc/os-release") { return fs::read("/etc/os-release") }
    if fs::is_file("/usr/lib/os-release") { return fs::read("/usr/lib/os-release") }
    Ok("")
}

fn gather(params: Value) -> Result[Value, string] {
    let text = os_release_text()?
    Ok(Value::Map(#{
        "family": Value::String(sys::family()),
        "name": Value::String(sys::os_name()),
        "version": Value::String(sys::os_version()),
        "kernel": Value::String(sys::kernel_version()),
        "arch": Value::String(sys::arch()),
        "id": Value::String(os_field(text, "ID")),
        "version_id": Value::String(os_field(text, "VERSION_ID")),
        "pretty_name": Value::String(os_field(text, "PRETTY_NAME"))
    }))
}
