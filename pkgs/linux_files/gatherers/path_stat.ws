use value
use fs
use common

fn gather(params: Value) -> Result[Value, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !fs::exists(p) {
        return Ok(Value::Map(#{
            "path": Value::String(p),
            "exists": Value::Bool(false)
        }))
    }
    let md = fs::metadata(p)?
    Ok(Value::Map(#{
        "path": Value::String(p),
        "exists": Value::Bool(true),
        "size": md.get("size").unwrap_or(Value::Int(0)),
        "is_file": md.get("is_file").unwrap_or(Value::Bool(false)),
        "is_dir": md.get("is_dir").unwrap_or(Value::Bool(false)),
        "is_symlink": md.get("is_symlink").unwrap_or(Value::Bool(false)),
        "mode": md.get("mode").unwrap_or(Value::Int(0)),
        "modified": md.get("modified").unwrap_or(Value::Int(0))
    }))
}
