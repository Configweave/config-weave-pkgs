use value
use shell
use fs
use path

fn verify(facts: Value) -> Result[bool, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "check.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n$m = @(Get-Module -ListAvailable -Name 'PSWriteColor' | ForEach-Object {{ [string]$_.Version }})\n$t = (Get-PSResourceRepository -Name PSGallery).Trusted\nWrite-Output ($m -join ',')\nWrite-Output ([string]$t)")?
    let out = shell::run("pwsh -NoProfile -NonInteractive -File \"" + file + "\"", Value::Null)
    fs::delete_dir(dir)?
    let result = out?
    if !result.success { return Err("querying the gallery install failed: " + result.stderr.trim()) }
    let lines = result.stdout.split("\n")
    if lines.len() < 2 { return Err("unexpected output: " + result.stdout) }
    if !lines[0].contains("1.0.1") { return Err("PSWriteColor 1.0.1 was not installed, found: " + lines[0].trim()) }
    if lines[1].trim() != "True" { return Err("PSGallery was not marked trusted") }
    Ok(true)
}
