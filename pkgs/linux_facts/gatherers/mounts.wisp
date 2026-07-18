use value
use fs

fn fields(line: string) -> List[string] {
    let f = []
    for p in line.split(" ") {
        if p != "" { f.push(p) }
    }
    f
}

fn gather(params: Value) -> Result[Value, string] {
    let text = if fs::exists("/proc/mounts") { fs::read("/proc/mounts")? } else { "" }
    let entries = []
    for line in text.split("\n") {
        if line.trim() == "" { continue }
        let p = fields(line)
        entries.push(Value::Map(#{
            "spec": Value::String(p.get(0).unwrap_or("")),
            "mountpoint": Value::String(p.get(1).unwrap_or("")),
            "fstype": Value::String(p.get(2).unwrap_or("")),
            "options": Value::String(p.get(3).unwrap_or(""))
        }))
    }
    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "mounts": Value::List(entries)
    }))
}
