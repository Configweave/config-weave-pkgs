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
    let has_root = [false]
    for line in text.split("\n") {
        if line.trim() == "" { continue }
        let p = fields(line)
        let mountpoint = p.get(1).unwrap_or("")
        if mountpoint == "/" { has_root.set(0, true) }
        entries.push(Value::Map(#{
            "spec": Value::String(p.get(0).unwrap_or("")),
            "mountpoint": Value::String(mountpoint),
            "fstype": Value::String(p.get(2).unwrap_or("")),
            "options": Value::String(p.get(3).unwrap_or(""))
        }))
    }
    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "has_root": Value::Bool(has_root.get(0).unwrap_or(false)),
        "mounts": Value::List(entries)
    }))
}
