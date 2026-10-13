use value
use fs
use json
use registry

fn dword(key: string, name: string) -> Result[int, string] {
    if let Some(v) = registry::read(key, name)? {
        if let Some(n) = v.as_int() { return Ok(n) }
    }
    Ok(-1)
}

fn sz(key: string, name: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, name)? {
        if let Some(s) = v.as_string() { return Ok(s) }
    }
    Ok("")
}

fn verify(facts: Value) -> Result[bool, string] {
    let core = registry::HKLM + "\\SOFTWARE\\Policies\\Microsoft\\PowerShellCore"

    // execution_policy wrote the per-user preference under the shell id,
    // and the machine policy under the PowerShell 7 policy key.
    let user_key = registry::HKCU + "\\SOFTWARE\\Microsoft\\PowerShell\\1\\ShellIds\\Microsoft.PowerShell"
    if sz(user_key, "ExecutionPolicy")? != "RemoteSigned" { return Err("the per-user execution policy was not written") }
    if sz(core, "ExecutionPolicy")? != "AllSigned" { return Err("the PowerShell 7 machine policy was not written") }

    if dword(core + "\\ScriptBlockLogging", "EnableScriptBlockLogging")? != 1 { return Ok(false) }
    if dword(core + "\\ScriptBlockLogging", "EnableScriptBlockInvocationLogging")? != 1 { return Ok(false) }
    if dword(core + "\\ModuleLogging", "EnableModuleLogging")? != 1 { return Ok(false) }
    if registry::read(core + "\\ModuleLogging\\ModuleNames", "CwExtra")?.is_some() { return Err("the module-logging name nobody asked for was left in the list") }
    if sz(registry::HKCU + "\\SOFTWARE\\Policies\\Microsoft\\PowerShellCore", "ExecutionPolicy")? != "" { return Err("the seeded user-policy execution policy was not removed") }
    let winps = registry::HKLM + "\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell"
    if dword(winps + "\\ModuleLogging", "EnableModuleLogging")? != 0 { return Err("Windows PowerShell module logging was not switched off") }
    if registry::key_exists(winps + "\\ModuleLogging\\ModuleNames")? { return Err("switching module logging off left its module list behind") }
    if sz(core + "\\ModuleLogging\\ModuleNames", "PSReadLine")? != "PSReadLine" { return Err("the module list was not written as name = name values") }
    if dword(core + "\\Transcription", "EnableTranscripting")? != 1 { return Ok(false) }
    if sz(core + "\\Transcription", "OutputDirectory")? != "C:\\weave-ps\\transcripts" { return Ok(false) }
    if dword(core + "\\ConsoleSessionConfiguration", "EnableConsoleSessionConfiguration")? != 1 { return Ok(false) }
    if sz(core + "\\ConsoleSessionConfiguration", "ConsoleSessionConfigurationName")? != "cwtest.endpoint" { return Ok(false) }

    // The config-file resources ran against an explicit path with no
    // PowerShell 7 on the box at all.
    let config = "C:\\weave-ps\\powershell.config.json"
    if !fs::is_file(config) { return Err("the scratch configuration file was not written") }
    let doc = json::parse(fs::read(config)?)?
    if doc.get("Microsoft.PowerShell:ExecutionPolicy").unwrap_or(Value::String("")).as_string().unwrap_or("") != "RemoteSigned" { return Ok(false) }
    if !doc.get("DisableImplicitWinCompat").unwrap_or(Value::Bool(false)).as_bool().unwrap_or(false) { return Ok(false) }

    // Windows PowerShell profiles live under Documents\WindowsPowerShell,
    // not Documents\PowerShell — that split is the whole point of `edition`.
    let base = "C:\\weave-ps\\home\\Documents\\WindowsPowerShell\\"
    let all_hosts = base + "profile.ps1"
    if !fs::is_file(all_hosts) {
        let found = if fs::is_dir(base) { fs::list_dir(base)?.join(", ") } else { "the directory does not exist" }
        return Err("expected the profile at " + all_hosts + " — that folder holds: " + found)
    }
    // Windows PowerShell 5.1 reads a BOM-less script as ANSI, so its
    // profiles are written with a UTF-8 BOM.
    if fs::read(all_hosts)? != "\u{FEFF}# managed by config-weave\n" { return Err("the all-hosts profile is not the declared content behind a UTF-8 BOM") }

    let host_profile = base + "Microsoft.PowerShell_profile.ps1"
    if !fs::is_file(host_profile) { return Err("the block-writing resources did not create the current-host profile") }
    let text = fs::read(host_profile)?
    if !text.contains("# BEGIN config-weave: greeting") { return Ok(false) }
    if !text.contains("Set-PSReadLineOption -EditMode Windows") { return Ok(false) }
    Ok(true)
}
