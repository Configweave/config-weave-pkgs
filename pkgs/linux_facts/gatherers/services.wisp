use value
use fs
use shell

fn fields(line: string) -> List[string] {
    let f = []
    for p in line.split(" ") {
        if p != "" { f.push(p) }
    }
    f
}

fn gather(params: Value) -> Result[Value, string] {
    let empty: Map[string, Value] = #{}
    if !fs::exists("/usr/bin/systemctl") && !fs::exists("/bin/systemctl") {
        return Ok(Value::Map(#{ "available": Value::Bool(false), "count": Value::Int(0), "services": Value::Map(empty) }))
    }
    let out = shell::bash("systemctl list-units --type=service --all --no-pager --no-legend --plain 2>/dev/null", Value::Null)?
    if !out.success {
        return Ok(Value::Map(#{ "available": Value::Bool(false), "count": Value::Int(0), "services": Value::Map(empty) }))
    }
    let svc: Map[string, Value] = #{}
    for line in out.stdout.split("\n") {
        if line.trim() == "" { continue }
        let p = fields(line)
        let name = p.get(0).unwrap_or("")
        if name == "" { continue }
        svc[name] = Value::Map(#{
            "active": Value::String(p.get(2).unwrap_or("")),
            "sub": Value::String(p.get(3).unwrap_or(""))
        })
    }
    Ok(Value::Map(#{
        "available": Value::Bool(true),
        "count": Value::Int(svc.len()),
        "services": Value::Map(svc)
    }))
}
