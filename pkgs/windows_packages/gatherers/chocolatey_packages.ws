use value
use common

fn empty_result() -> Value {
    let none: List[Value] = []
    Value::Map(#{ "count": Value::Int(0), "packages": Value::List(none) })
}

// `choco list --limit-output` prints one "name|version" line per installed
// package (Chocolatey 1.x needs --local-only for that). A machine without
// Chocolatey gathers the empty shape; a listing that fails is an error.
fn gather(params: Value) -> Result[Value, string] {
    let out = common::query(common::choco_ps() + "& $choco list --limit-output @chocoLocal\nexit $LASTEXITCODE\n", #{})?
    if out.code == common::missing_code() { return Ok(empty_result()) }
    if !out.success { return Err(common::failure("choco list", out)) }

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
