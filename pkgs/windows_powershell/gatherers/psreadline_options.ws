use value
use json
use common

fn unavailable() -> Value {
    let empty: Map[string, Value] = #{}
    Value::Map(#{
        "available": Value::Bool(false),
        "module_version": Value::String(""),
        "edit_mode": Value::String(""),
        "prediction_source": Value::String(""),
        "prediction_view_style": Value::String(""),
        "history_save_style": Value::String(""),
        "history_save_path": Value::String(""),
        "maximum_history_count": Value::Int(-1),
        "options": Value::Map(empty)
    })
}

fn scalar(options: Value, key: string) -> string {
    if let Some(v) = options.get(key) {
        if let Some(s) = v.as_string() { return s }
        if let Some(n) = v.as_int() { return str(n) }
        if let Some(b) = v.as_bool() { return str(b) }
    }
    ""
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = common::param_str(params, "edition", "auto")
    // Only the scalar properties: the colour properties are ConsoleColor
    // objects that do not survive a JSON round trip usefully. A PSReadLine
    // that cannot be loaded is a fact (unavailable): an explicit `exit 0`
    // with no output, since a script-level `return` after a caught error
    // leaves the exit code to `$?`. Any other failure is an error.
    let script = "try {{ Import-Module PSReadLine -ErrorAction Stop }} catch {{ exit 0 }}\n$o = Get-PSReadLineOption\n$m = (Get-Module PSReadLine).Version.ToString()\n$out = [ordered]@{{ module_version = $m }}\nforeach ($p in $o.PSObject.Properties) {{ if ($p.Value -is [string] -or $p.Value -is [int] -or $p.Value -is [bool] -or $p.Value -is [enum]) {{ $out[$p.Name] = [string]$p.Value }} }}\n$out | ConvertTo-Json -Compress -Depth 3"
    let text = common::query(edition, script)?.unwrap_or("")
    if text == "" { return Ok(unavailable()) }
    let options = json::parse(text)?
    Ok(Value::Map(#{
        "available": Value::Bool(true),
        "module_version": Value::String(scalar(options, "module_version")),
        "edit_mode": Value::String(scalar(options, "EditMode")),
        "prediction_source": Value::String(scalar(options, "PredictionSource")),
        "prediction_view_style": Value::String(scalar(options, "PredictionViewStyle")),
        "history_save_style": Value::String(scalar(options, "HistorySaveStyle")),
        "history_save_path": Value::String(scalar(options, "HistorySavePath")),
        "maximum_history_count": Value::Int(scalar(options, "MaximumHistoryCount").parse_int().unwrap_or(-1)),
        "options": options
    }))
}
