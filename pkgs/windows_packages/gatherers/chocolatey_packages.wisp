use value
use shell

fn empty_result() -> Value {
    let none: List[Value] = []
    Value::Map(#{ "count": Value::Int(0), "packages": Value::List(none) })
}

// `choco list --limit-output` prints one "name|version" line per installed
// package. A machine without Chocolatey gathers the empty shape.
fn gather(params: Value) -> Result[Value, string] {
    let script = "if (Get-Command choco -ErrorAction SilentlyContinue) {{ choco list --limit-output; exit $LASTEXITCODE }} else {{ exit 9009 }}"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Ok(empty_result()) }

    let entries = []
    for line in out.stdout.split("\n") {
        let t = line.trim()
        if t == "" { continue }
        if let Some(i) = t.find("|") {
            entries.push(Value::Map(#{
                "name": Value::String(t.slice(0, i)),
                "version": Value::String(t.slice(i + 1, t.len()))
            }))
        }
    }

    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "packages": Value::List(entries)
    }))
}
