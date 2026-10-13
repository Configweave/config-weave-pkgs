use value
use common

// Wildcards are PowerShell's (* ? [abc]), matched against names in the
// root directory only, or below it with `recurse`.
fn gather(params: Value) -> Result[Value, string] {
    let root = common::param_str(params, "path", "")
    common::require_path("path", root)?
    let pattern = common::param_str(params, "pattern", "*")
    if pattern.contains("\\") || pattern.contains("/") { return Err("'pattern' matches names, so it must not contain a path separator; set 'recurse' to search below the root") }
    let recurse = common::param_bool(params, "recurse", false)
    let st = common::ps_json("listing " + root,
        "$root = " + common::ps_q(root) + "\n" +
        "if (-not (Test-Path -LiteralPath $root -PathType Container)) {{ throw ('not a directory: ' + $root) }}\n" +
        "$m = @(Get-ChildItem -LiteralPath $root -Force" + (if recurse { " -Recurse" } else { "" }) + " -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -like " + common::ps_q(pattern) + " }} | ForEach-Object {{ $_.FullName }} | Sort-Object)\n" +
        "[pscustomobject]@{{ matches = $m }} | ConvertTo-Json -Compress\n"
    )?
    let matches = common::get_list(st, "matches")
    Ok(Value::Map(#{
        "root": Value::String(root),
        "pattern": Value::String(pattern),
        "count": Value::Int(matches.len()),
        "matches": Value::List(matches)
    }))
}
