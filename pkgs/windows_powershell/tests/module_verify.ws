use value
use shell
use fs
use path

fn versions_of(name: string) -> Result[List[string], string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "mods.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n@(Get-Module -ListAvailable -Name '" + name + "' | ForEach-Object {{ [string]$_.Version }}) -join \"`n\"")?
    let out = shell::run("pwsh -NoProfile -NonInteractive -File \"" + file + "\"", Value::Null)
    fs::delete_dir(dir)?
    let result = out?
    let found: List[string] = []
    if !result.success { return Ok(found) }
    for line in result.stdout.split("\n") {
        let trimmed = line.trim()
        if trimmed != "" { found.push(trimmed) }
    }
    Ok(found)
}

fn verify(facts: Value) -> Result[bool, string] {
    // The newest version was installed when no version was pinned.
    let sample = versions_of("CwSample")?
    if !sample.contains("1.2.0") { return Err("CwSample 1.2.0 (the newest in the feed) was not installed, found: " + sample.join(",")) }

    // The pin took the older version, not the newest.
    let pinned = versions_of("CwPinned")?
    if !pinned.contains("1.0.0") { return Err("the pinned CwPinned 1.0.0 was not installed, found: " + pinned.join(",")) }
    if pinned.contains("2.0.0") { return Err("the version pin was ignored and 2.0.0 was installed") }

    // The module setup pre-installed was removed.
    let seeded = versions_of("CwSeeded")?
    if !seeded.is_empty() { return Err("CwSeeded was not uninstalled, found: " + seeded.join(",")) }

    // The prerelease pin installed the prerelease.
    if versions_of("CwPre")?.is_empty() { return Err("the prerelease CwPre was not installed") }

    // Nothing was installed from the untrusted repository.
    if !versions_of("CwUntrusted")?.is_empty() { return Err("a module was installed from an untrusted repository without trust_repository") }

    // The module installed only machine-wide is still there: the
    // current-user :absent step must not have touched it.
    if versions_of("CwOtherScope")?.is_empty() { return Err("the current-user :absent step removed a machine-wide module") }

    // script_resource installed one script and removed the seeded one.
    if !fs::is_file("/usr/local/share/powershell/Scripts/CwScript.ps1") { return Err("CwScript was not installed machine-wide") }
    if fs::exists("/usr/local/share/powershell/Scripts/CwScriptSeeded.ps1") { return Err("the seeded script was not uninstalled") }

    // The named update ran and wrote its own qualified stamp.
    let stamps = fs::glob("/var/lib/config-weave/powershell-modules-updated-*")?
    if stamps.len() != 1 { return Err("expected one qualified modules stamp, found " + str(stamps.len())) }

    // The failed help update did not advance its window.
    if fs::exists("/var/lib/config-weave/cw-help-failed") { return Err("help_updated stamped a run in which every module failed") }

    // The stamp files the update-window steps relied on are still fresh.
    if !fs::is_file("/var/lib/config-weave/cw-modules-updated") { return Err("the modules update stamp vanished") }
    Ok(true)
}
