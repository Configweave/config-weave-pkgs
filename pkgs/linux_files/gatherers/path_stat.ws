use value
use fs
use common

// Describes the path itself, never what a symlink points at (fs::metadata
// is lstat): a dangling symlink exists, and a symlink to a directory is
// is_symlink, not is_dir.
fn gather(params: Value) -> Result[Value, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !fs::lexists(p) {
        return Ok(Value::Map(#{
            "path": Value::String(p),
            "exists": Value::Bool(false)
        }))
    }
    let md = fs::metadata(p)?
    // mode is the permission bits only (st_mode & 0o7777), as of
    // config-weave v0.7.0-alpha
    let mode = if let Some(m) = md.get("mode") { m.as_int().unwrap_or(0) } else { 0 }
    Ok(Value::Map(#{
        "path": Value::String(p),
        "exists": Value::Bool(true),
        "size": md.get("size").unwrap_or(Value::Int(0)),
        "is_file": md.get("is_file").unwrap_or(Value::Bool(false)),
        "is_dir": md.get("is_dir").unwrap_or(Value::Bool(false)),
        "is_symlink": md.get("is_symlink").unwrap_or(Value::Bool(false)),
        "mode": Value::Int(mode),
        "modified": md.get("modified").unwrap_or(Value::Int(0))
    }))
}
