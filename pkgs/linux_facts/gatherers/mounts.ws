use value
use fs
use common

fn gather(params: Value) -> Result[Value, string] {
    let text = if fs::exists("/proc/mounts") { fs::read("/proc/mounts")? } else { "" }
    let entries = []
    for line in text.split("\n") {
        if line.trim() == "" { continue }
        let p = common::fields(line)
        entries.push(Value::Map(#{
            "spec": Value::String(common::unescape_octal(p.get(0).unwrap_or(""))),
            "mountpoint": Value::String(common::unescape_octal(p.get(1).unwrap_or(""))),
            "fstype": Value::String(p.get(2).unwrap_or("")),
            "options": Value::String(p.get(3).unwrap_or(""))
        }))
    }
    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "mounts": Value::List(entries)
    }))
}
