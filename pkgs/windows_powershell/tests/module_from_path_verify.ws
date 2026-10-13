use value
use fs
use path
use shell
use json

// What PowerShell itself sees, with HOME pointed at the test home so its
// per-user module directory is the one the steps installed into.
fn listed(name: string) -> Result[List[string], string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "list.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n@(Get-Module -ListAvailable -Name '" + name + "' | ForEach-Object {{ [string]$_.Version + ' ' + $_.ModuleBase }}) -join \"`n\"")?
    let out = shell::run("pwsh -NoProfile -NonInteractive -File \"" + file + "\"", Value::Map(#{ "env": Value::Map(#{ "HOME": Value::String("/cwhome3") }) }))
    fs::delete_dir(dir)?
    let result = out?
    if !result.success { return Err("Get-Module failed: " + result.stderr.trim()) }
    let found: List[string] = []
    for line in result.stdout.split("\n") {
        if line.trim() != "" { found.push(line.trim()) }
    }
    Ok(found)
}

fn verify(facts: Value) -> Result[bool, string] {
    let base = "/cwhome3/.local/share/powershell/Modules"
    let dir_mod = listed("CwLocalDir")?
    if dir_mod != ["2.1.0 " + base + "/CwLocalDir/2.1.0"] { return Err("Get-Module -ListAvailable reports CwLocalDir as: " + dir_mod.join("; ")) }
    let zip_mod = listed("CwLocalZip")?
    if zip_mod != ["1.4.2 " + base + "/CwLocalZip/1.4.2"] { return Err("Get-Module -ListAvailable reports CwLocalZip as: " + zip_mod.join("; ")) }

    // The stale copy was replaced with the source's content.
    if fs::read(base + "/CwLocalDir/2.1.0/CwLocalDir.psm1")? != fs::read("/srv/cwsrc/CwLocalDir/CwLocalDir.psm1")? {
        return Err("the stale CwLocalDir content was not replaced")
    }
    // strip_root must not have left the archive's wrapper directory behind.
    if fs::exists(base + "/CwLocalZip/1.4.2/CwLocalZip") { return Err("strip_root left the archive's top-level directory in place") }
    if fs::exists(base + "/CwMismatch") { return Err("a module whose manifest contradicts its version folder was installed anyway") }
    if fs::exists(base + "/CwSeededManual") { return Err("the hand-installed module was not removed") }
    if !listed("CwSeededManual")?.is_empty() { return Err("PowerShell still lists the removed module") }
    Ok(true)
}
