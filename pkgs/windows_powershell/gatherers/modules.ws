use value
use json
use common

fn empty_result() -> Value {
    let none: List[Value] = []
    let names: List[Value] = []
    Value::Map(#{
        "count": Value::Int(0),
        "found": Value::Bool(false),
        "names": Value::List(names),
        "modules": Value::List(none)
    })
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = common::param_str(params, "edition", "auto")
    let name = common::param_str(params, "name", "")
    let filter = if name == "" { "*" } else { name }
    // Get-Module -ListAvailable rather than the provider inventory: it sees
    // in-box and hand-installed modules too, which is what "installed" means.
    let script = "@(Get-Module -ListAvailable -Name " + common::ps_q(filter) + " | Select-Object @{{n='name';e={{[string]$_.Name}}}}, @{{n='version';e={{[string]$_.Version}}}}, @{{n='repository';e={{[string]$_.RepositorySourceLocation}}}}, @{{n='path';e={{[string]$_.ModuleBase}}}}) | ConvertTo-Json -Compress"
    // A PowerShell that is not installed reports the empty shape; one that
    // cannot answer is an error.
    let answered = common::query(edition, script)?
    if answered.is_none() { return Ok(empty_result()) }
    let entries: List[Value] = []
    let text = answered.unwrap()
    if text != "" {
        let parsed = json::parse(text)?
        // Windows PowerShell collapses a single-element array into a bare
        // object, so both shapes are accepted.
        if let Some(items) = parsed.as_list() {
            for item in items { entries.push(item) }
        } else if !parsed.is_null() {
            entries.push(parsed)
        }
    }
    if entries.is_empty() { return Ok(empty_result()) }

    // Scope filtering is a path-prefix test against the two directories the
    // module resource installs into, so the gatherer and the resource agree
    // on what a scope holds. In-box modules ($PSHOME, System32) belong to
    // neither.
    let scope = common::param_str(params, "scope", "any")
    let root = ""
    if scope != "any" {
        let expr = if scope == "all_users" {
            "if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path $env:ProgramFiles 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path $env:ProgramFiles 'PowerShell\\Modules' }} else {{ '/usr/local/share/powershell/Modules' }}"
        } else {
            "if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path ([Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')) 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path ([Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')) 'PowerShell\\Modules' }} else {{ Join-Path $HOME '.local/share/powershell/Modules' }}"
        }
        root = common::query(edition, expr)?.unwrap_or("").replace("\\", "/").to_lower()
        if !root.ends_with("/") { root = root + "/" }
    }
    let kept: List[Value] = []
    for entry in entries {
        let where = entry.get("path").unwrap_or(Value::String("")).as_string().unwrap_or("").replace("\\", "/").to_lower()
        if scope == "any" || where.starts_with(root) { kept.push(entry) }
    }

    let names: List[Value] = []
    for entry in kept {
        if let Some(n) = entry.get("name") { names.push(n) }
    }
    Ok(Value::Map(#{
        "count": Value::Int(kept.len()),
        "found": Value::Bool(!kept.is_empty()),
        "names": Value::List(names),
        "modules": Value::List(kept)
    }))
}
