use value
use fs
use config_file

// A PowerShell that is not installed resolves no file and reports the empty
// shape; one that is installed but cannot answer is an error.
fn gather(params: Value) -> Result[Value, string] {
    // a link in a user's tree is an error, never read through
    let file = config_file::config_path(params)?.unwrap_or("")
    let empty: Map[string, Value] = #{}
    let none: List[Value] = []
    if file == "" || !fs::is_file(file) {
        return Ok(Value::Map(#{
            "exists": Value::Bool(false),
            "path": Value::String(file),
            "settings": Value::Map(empty),
            "execution_policy": Value::String(""),
            "psmodulepath": Value::String(""),
            "experimental_features": Value::List(none)
        }))
    }
    let doc = config_file::read_doc(config_file::user_root(params), file)?
    let features: List[Value] = []
    if let Some(v) = doc.get("ExperimentalFeatures") {
        if let Some(items) = v.as_list() {
            for item in items { features.push(item) }
        }
    }
    Ok(Value::Map(#{
        "exists": Value::Bool(true),
        "path": Value::String(file),
        "settings": doc,
        "execution_policy": Value::String(doc.get("Microsoft.PowerShell:ExecutionPolicy").unwrap_or(Value::String("")).as_string().unwrap_or("")),
        "psmodulepath": Value::String(doc.get("PSModulePath").unwrap_or(Value::String("")).as_string().unwrap_or("")),
        "experimental_features": Value::List(features)
    }))
}
