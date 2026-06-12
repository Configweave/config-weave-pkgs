use value
use fs
use sys

fn strip_quotes(s: string) -> string {
    let t = s.trim()
    if t.starts_with("\"") && t.ends_with("\"") && t.len() >= 2 {
        return t.slice(1, t.len() - 1)
    }
    t
}

fn os_field(text: string, key: string) -> string {
    for line in text.split("\n") {
        let prefix = key + "="
        if line.starts_with(prefix) {
            return strip_quotes(line.slice(prefix.len(), line.len()))
        }
    }
    ""
}

fn gather(params: Value) -> Result[Value, string] {
    let text = if fs::exists("/etc/os-release") { fs::read("/etc/os-release")? } else { "" }
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

