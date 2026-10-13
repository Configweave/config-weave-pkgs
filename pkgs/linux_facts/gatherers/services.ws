use value
use shell
use common

fn systemctl(args: string) -> Option[string] {
    let out = shell::bash("systemctl " + args + " --type=service --no-pager --no-legend --plain 2>/dev/null", Value::Null).unwrap_or(CmdOutput { stdout: "", stderr: "", code: 127, success: false })
    if out.success { Some(out.stdout) } else { None }
}

// A failed unit can lead with a status bullet; the name is the first
// field that is not one.
fn unit_fields(line: string) -> List[string] {
    let p = common::fields(line)
    if p.get(0).unwrap_or("") == "●" || p.get(0).unwrap_or("") == "*" { return p.slice(1, p.len()) }
    p
}

fn gather(params: Value) -> Result[Value, string] {
    // No service manager => no services: an Err here would abort the whole
    // gather phase on non-systemd hosts (and in containers, where systemctl
    // is missing or cannot reach systemd). Consumers disambiguate via
    // init_system.init.
    let none: List[Value] = []
    let Some(units) = systemctl("list-units --all") else {
        return Ok(Value::Map(#{ "services": Value::List(none) }))
    }

    // Unit-file state (enabled, disabled, static, masked, ...) by name.
    // Templates (foo@.service) are not services that can run and are left out.
    let states: Map[string, string] = #{}
    for line in systemctl("list-unit-files").unwrap_or("").split("\n") {
        let p = unit_fields(line)
        let name = p.get(0).unwrap_or("")
        if name == "" || name.ends_with("@.service") { continue }
        states.insert(name, p.get(1).unwrap_or(""))
    }

    let svc = []
    let seen: Map[string, bool] = #{}
    for line in units.split("\n") {
        let p = unit_fields(line)
        let name = p.get(0).unwrap_or("")
        if name == "" { continue }
        seen.insert(name, true)
        svc.push(Value::Map(#{
            "name": Value::String(name),
            "active": Value::String(p.get(2).unwrap_or("")),
            "sub": Value::String(p.get(3).unwrap_or("")),
            "enabled": Value::String(states.get(name).unwrap_or(""))
        }))
    }
    // Installed but never loaded (disabled and not depended on): systemd
    // does not list these as units at all.
    let names = states.keys()
    names.sort()
    for name in names {
        if seen.contains_key(name) { continue }
        svc.push(Value::Map(#{
            "name": Value::String(name),
            "active": Value::String("inactive"),
            "sub": Value::String("dead"),
            "enabled": Value::String(states.get(name).unwrap_or(""))
        }))
    }
    Ok(Value::Map(#{
        "services": Value::List(svc)
    }))
}
