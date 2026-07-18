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
    // No service manager => no services: an Err here would abort the whole
    // gather phase on non-systemd hosts (and in containers, where systemctl
    // fails). Consumers disambiguate via init_system.init.
    let none: List[Value] = []
    if !fs::exists("/usr/bin/systemctl") && !fs::exists("/bin/systemctl") {
        return Ok(Value::Map(#{ "services": Value::List(none) }))
    }
    let out = shell::bash("systemctl list-units --type=service --all --no-pager --no-legend --plain 2>/dev/null", Value::Null)?
    if !out.success {
        return Ok(Value::Map(#{ "services": Value::List(none) }))
    }
    let svc = []
    for line in out.stdout.split("\n") {
        if line.trim() == "" { continue }
        let p = fields(line)
        let name = p.get(0).unwrap_or("")
        if name == "" { continue }
        svc.push(Value::Map(#{
            "name": Value::String(name),
            "active": Value::String(p.get(2).unwrap_or("")),
            "sub": Value::String(p.get(3).unwrap_or(""))
        }))
    }
    Ok(Value::Map(#{
        "services": Value::List(svc)
    }))
}
