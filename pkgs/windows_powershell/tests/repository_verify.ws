use value
use shell
use fs
use path
use json

fn repositories() -> Result[Value, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "repos.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n@(Get-PSResourceRepository | Select-Object @{{n='name';e={{[string]$_.Name}}}}, @{{n='uri';e={{[string]$_.Uri}}}}, @{{n='trusted';e={{[bool]$_.Trusted}}}}, @{{n='priority';e={{[int]$_.Priority}}}}) | ConvertTo-Json -Compress")?
    let out = shell::run("pwsh -NoProfile -NonInteractive -File \"" + file + "\"", Value::Null)
    fs::delete_dir(dir)?
    let result = out?
    if !result.success { return Err("listing repositories failed: " + result.stderr.trim()) }
    json::parse(result.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    let listed = repositories()?
    let items = listed.as_list().unwrap_or([])
    let found = false
    for item in items {
        let name = item.get("name").unwrap_or(Value::String("")).as_string().unwrap_or("")
        if name == "cwstale" { return Err("the repository seeded by setup was not unregistered") }
        if name == "cwlocal" {
            found = true
            if !item.get("trusted").unwrap_or(Value::Bool(false)).as_bool().unwrap_or(false) {
                return Err("the repository was registered but not marked trusted")
            }
            if item.get("priority").unwrap_or(Value::Int(-1)).as_int().unwrap_or(-1) != 10 {
                return Err("the repository priority was not applied")
            }
        }
    }
    if !found { return Err("the cwlocal repository was not registered") }
    Ok(true)
}
