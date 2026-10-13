use value
use json
use common

// PowerShell that enumerates the scoop root's apps\* dirs, resolving each
// app's `current` junction target dir name as the installed version, and
// emits one JSON object. Scoop is per-user: the SCOOP env var wins, else
// ~\scoop.
fn apps_ps() -> string {
    common::scoop_root_ps() +
    "$apps = @()\n" +
    "$dir = Join-Path $scoopRoot 'apps'\n" +
    "if (Test-Path -LiteralPath $dir) {{\n" +
    "  $apps = @(Get-ChildItem -Directory -LiteralPath $dir | ForEach-Object {{\n" +
    "    $ver = ''\n" +
    "    $cur = Join-Path $_.FullName 'current'\n" +
    "    if (Test-Path -LiteralPath $cur) {{\n" +
    "      $t = (Get-Item -LiteralPath $cur).Target | Select-Object -First 1\n" +
    "      if ($t) {{ $ver = Split-Path -Leaf ([string]$t) }}\n" +
    "    }}\n" +
    "    [pscustomobject]@{{ name = $_.Name; version = [string]$ver }}\n" +
    "  }})\n" +
    "}}\n" +
    "ConvertTo-Json -Compress -Depth 4 -InputObject @{{ count = $apps.Count; packages = $apps }}\n"
}

fn entry(m: Value) -> Value {
    Value::Map(#{
        "name": Value::String(common::get_str(m, "name")),
        "version": Value::String(common::get_str(m, "version"))
    })
}

fn gather(params: Value) -> Result[Value, string] {
    let out = common::query(apps_ps(), #{})?
    if !out.success { return Err(common::failure("listing scoop apps", out)) }
    let m = json::parse(out.stdout.trim())?

    // ConvertTo-Json in Windows PowerShell 5.1 collapses a single-element
    // array to its element, so packages may arrive as one bare map.
    let entries = []
    if let Some(v) = m.get("packages") {
        if let Some(items) = v.as_list() {
            for item in items { entries.push(entry(item)) }
        } else if let Some(single) = v.as_map() {
            entries.push(entry(Value::Map(single)))
        }
    }

    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "packages": Value::List(entries)
    }))
}
