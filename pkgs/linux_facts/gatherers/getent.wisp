use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn gather(params: Value) -> Result[Value, string] {
    let database = param_str(params, "database", "")
    let key = param_str(params, "key", "")
    if database == "" { return Err("missing 'database' parameter") }
    let cmd = if key != "" { "getent " + q(database) + " " + q(key) } else { "getent " + q(database) }
    let out = shell::bash(cmd, Value::Null)?
    let found = out.success && out.stdout.trim() != ""
    let first = out.stdout.trim().split("\n").get(0).unwrap_or("")
    Ok(Value::Map(#{
        "database": Value::String(database),
        "key": Value::String(key),
        "found": Value::Bool(found),
        "value": Value::String(first)
    }))
}
