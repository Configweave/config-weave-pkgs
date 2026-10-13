use value
use fs
use common

fn gather(params: Value) -> Result[Value, string] {
    let root = common::param_str(params, "path", "")
    let pattern = common::param_str(params, "pattern", "*")
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
