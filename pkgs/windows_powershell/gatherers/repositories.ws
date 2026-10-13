use value
use json
use common
use psget

fn empty_result() -> Value {
    let none: List[Value] = []
    let names: List[Value] = []
    Value::Map(#{
        "count": Value::Int(0),
        "provider": Value::String("none"),
        "names": Value::List(names),
        "repositories": Value::List(none)
    })
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = common::param_str(params, "edition", "auto")
    // A PowerShell that is not installed reports the empty shape; one that
    // cannot answer is an error.
    if !common::ps_installed(edition) { return Ok(empty_result()) }
    let kind = psget::provider(params)?

    let script = if kind == "psresourceget" {
        "@(Get-PSResourceRepository | Select-Object @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.Uri}}}}, @{{n='trusted';e={{[bool]$_.Trusted}}}}, @{{n='priority';e={{[int]$_.Priority}}}}, @{{n='api_version';e={{[string]$_.ApiVersion}}}}) | ConvertTo-Json -Compress"
    } else {
        "@(Get-PSRepository | Select-Object @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.SourceLocation}}}}, @{{n='trusted';e={{$_.InstallationPolicy -eq 'Trusted'}}}}, @{{n='priority';e={{-1}}}}, @{{n='api_version';e={{''}}}}) | ConvertTo-Json -Compress"
    }
    let text = common::query(edition, psget::import_line(kind) + script)?.unwrap_or("")
    let entries: List[Value] = []
    let names: List[Value] = []
    if text != "" {
        let parsed = json::parse(text)?
        // Windows PowerShell collapses a single-element array into a bare
        // object, so both shapes have to be accepted.
        if let Some(items) = parsed.as_list() {
            for item in items { entries.push(item) }
        } else if !parsed.is_null() {
            entries.push(parsed)
        }
    }
    for entry in entries {
        if let Some(n) = entry.get("name") { names.push(n) }
    }
    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "provider": Value::String(kind),
        "names": Value::List(names),
        "repositories": Value::List(entries)
    }))
}
