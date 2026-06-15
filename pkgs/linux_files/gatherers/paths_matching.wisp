use value
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn gather(params: Value) -> Result[Value, string] {
    let root = param_str(params, "path", "")
    let pattern = param_str(params, "pattern", "*")
    if root == "" { return Err("missing 'path' parameter") }
    let matches = fs::glob(root + "/" + pattern)?
    let as_values = matches.map(|m| Value::String(m))
    Ok(Value::Map(#{
        "root": Value::String(root),
        "pattern": Value::String(pattern),
        "count": Value::Int(as_values.len()),
        "matches": Value::List(as_values)
    }))
}
