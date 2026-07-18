use value
use shell
use json

// PowerShell that enumerates the scoop root's apps\* dirs, resolving each
// app's `current` junction target dir name as the installed version, and
// emits one JSON object. Scoop is per-user: the SCOOP env var wins, else
// ~\scoop.
fn apps_ps() -> string {
    "$ErrorActionPreference='Stop'; " +
    "$root = if ($env:SCOOP) {{ $env:SCOOP }} else {{ \"$env:USERPROFILE\\scoop\" }}; " +
    "$apps = @(); " +
    "if (Test-Path \"$root\\apps\") {{ " +
        "$apps = @(Get-ChildItem -Directory \"$root\\apps\" | ForEach-Object {{ " +
            "$ver = ''; " +
            "$cur = Join-Path $_.FullName 'current'; " +
            "if (Test-Path $cur) {{ " +
                "$t = (Get-Item $cur).Target | Select-Object -First 1; " +
                "if ($t) {{ $ver = Split-Path -Leaf \"$t\" }} " +
            "}}; " +
            "[pscustomobject]@{{ name = $_.Name; version = \"$ver\" }} " +
        "}}) " +
    "}}; " +
    "[pscustomobject]@{{ count = $apps.Count; packages = $apps }} | ConvertTo-Json -Compress -Depth 4"
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn entry(m: Value) -> Value {
    Value::Map(#{
        "name": Value::String(get_str(m, "name")),
        "version": Value::String(get_str(m, "version"))
    })
}

fn empty_result() -> Value {
    let none: List[Value] = []
    Value::Map(#{ "count": Value::Int(0), "packages": Value::List(none) })
}

fn gather(params: Value) -> Result[Value, string] {
    let out = shell::powershell(apps_ps(), Value::Null)?
    if !out.success { return Ok(empty_result()) }
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
