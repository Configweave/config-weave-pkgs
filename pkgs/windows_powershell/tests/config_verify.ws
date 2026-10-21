use value
use fs
use shell
use path
use json

fn at(doc: Value, keys: List[string]) -> Value {
    let cur = doc
    for k in keys {
        if let Some(next) = cur.get(k) { cur = next } else { return Value::Null }
    }
    cur
}

// The values PowerShell's own configuration reader returns for a file.
// Console.Out rather than Write-Output: the file replaces PSModulePath, so
// Microsoft.PowerShell.Utility may not load.
fn parsed_settings(file: string) -> Result[List[string], string] {
    let dir = fs::temp_dir()?
    let script = path::join(dir, "parse.ps1")
    fs::write(script, "$ErrorActionPreference = 'Stop'\n$t = [psobject].Assembly.GetType('System.Management.Automation.Configuration.PowerShellConfig')\n$i = $t.GetField('Instance', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)\n$f = [Reflection.BindingFlags]'Instance,NonPublic'\n$ch = $t.GetMethod('GetLogChannels', $f).Invoke($i, $null)\n$kw = $t.GetMethod('GetLogKeywords', $f).Invoke($i, $null)\n$cht = $ch.GetType(); $kwt = $kw.GetType()\n[Console]::Out.WriteLine([string]$t.GetMethod('GetLogLevel', $f).Invoke($i, $null))\n[Console]::Out.WriteLine([string]([long]$ch -eq ([long][enum]::Parse($cht, 'Operational') -bor [long][enum]::Parse($cht, 'Analytic'))))\n[Console]::Out.WriteLine([string]([long]$kw -eq ([long][enum]::Parse($kwt, 'Runspace') -bor [long][enum]::Parse($kwt, 'Pipeline'))))\n[Console]::Out.WriteLine([string]$t.GetMethod('GetSysLogIdentity', $f).Invoke($i, $null))\n[Console]::Out.WriteLine([string]$t.GetMethod('GetExecutionPolicy', $f).Invoke($i, @([System.Management.Automation.Configuration.ConfigScope]::AllUsers, 'Microsoft.PowerShell')))\n")?
    let out = shell::run("pwsh -NoProfile -NonInteractive -SettingsFile " + file + " -File " + script, Value::Null)
    fs::delete_dir(dir)?
    let result = out?
    if !result.success { return Err("PowerShell could not read the configuration back: " + result.stderr.trim() + " " + result.stdout.trim()) }
    let lines: List[string] = []
    for line in result.stdout.split("\n") {
        if line.trim() != "" { lines.push(line.trim()) }
    }
    Ok(lines)
}

fn verify(facts: Value) -> Result[bool, string] {
    let file = "/etc/cw/powershell.config.json"
    if !fs::is_file(file) { return Err("the configuration file was not written") }
    let doc = json::parse(fs::read(file)?)?

    // config_setting, literal and dotted
    if at(doc, ["Microsoft.PowerShell:ExecutionPolicy"]).as_string().unwrap_or("") != "RemoteSigned" { return Ok(false) }
    if at(doc, ["PowerShellPolicies", "ScriptBlockLogging", "EnableScriptBlockLogging"]).as_bool().unwrap_or(false) != true { return Ok(false) }
    // the key seeded by setup was removed
    if !at(doc, ["CWStale"]).is_null() { return Ok(false) }

    // :exact replaced PSModulePath with exactly the two entries, in order
    let module_path = at(doc, ["PSModulePath"]).as_string().unwrap_or("")
    if module_path != "/opt/cw/modules:/srv/cw/modules" { return Err("PSModulePath is '" + module_path + "'") }

    // :merge kept what the file already carried and appended
    let merged = json::parse(fs::read("/etc/cw/merge.config.json")?)?
    let merged_path = at(merged, ["PSModulePath"]).as_string().unwrap_or("")
    if merged_path != "/seeded/one:/seeded/two:/opt/cw/modules" { return Err("the merged PSModulePath is '" + merged_path + "'") }

    // The refused merge must not have written anything at all.
    if fs::exists("/etc/cw/defaults.config.json") {
        return Err("the refused merge wrote a configuration file anyway")
    }

    // The real $PSHOME file is the one that matters: a malformed value there
    // stops PowerShell starting at all ("The shell cannot be started"). Prove
    // the shell still runs, and that it still sees both its own module
    // directory and the one that was merged in.
    let out = shell::run("pwsh -NoProfile -NonInteractive -Command $env:PSModulePath", Value::Null)?
    if !out.success {
        return Err("PowerShell will not start after writing its $PSHOME configuration: " + out.stderr.trim() + " " + out.stdout.trim())
    }
    let effective = out.stdout.trim()
    if !effective.contains("/opt/cw/modules") { return Err("the merged entry is not on the effective PSModulePath: '" + effective + "'") }
    if !effective.contains("/opt/microsoft/powershell/7/Modules") {
        return Err("the shipped module directory fell off the effective PSModulePath: '" + effective + "'")
    }

    // experimental_feature added one and removed the seeded one
    let features: List[string] = []
    if let Some(items) = at(doc, ["ExperimentalFeatures"]).as_list() {
        for item in items { features.push(item.as_string().unwrap_or("")) }
    }
    if !features.contains("PSCommandNotFoundSuggestion") { return Ok(false) }
    if features.contains("PSStale") { return Ok(false) }

    // win_compat
    if at(doc, ["DisableImplicitWinCompat"]).as_bool().unwrap_or(false) != true { return Ok(false) }
    let deny: List[string] = []
    if let Some(items) = at(doc, ["WindowsPowerShellCompatibilityModuleDenyList"]).as_list() {
        for item in items { deny.push(item.as_string().unwrap_or("")) }
    }
    if deny != ["PSScheduledJob", "BitsTransfer"] { return Ok(false) }

    // execution_policy wrote PowerShell 7's preference scopes into the
    // configuration files, not the registry.
    let user_cfg = json::parse(fs::read("/cwep/.config/powershell/powershell.config.json")?)?
    if at(user_cfg, ["Microsoft.PowerShell:ExecutionPolicy"]).as_string().unwrap_or("") != "AllSigned" { return Err("the PowerShell 7 current-user execution policy was not written to the user's configuration file") }
    let ep = json::parse(fs::read("/etc/cw/ep.config.json")?)?
    if !at(ep, ["Microsoft.PowerShell:ExecutionPolicy"]).is_null() { return Err("the seeded machine execution policy was not removed") }
    if at(ep, ["CWKeep"]).as_int().unwrap_or(0) != 1 { return Err("removing the execution policy lost another key") }

    // The links planted in the user homes are left alone, and so are their
    // targets: nothing was written through them.
    if fs::read_link("/cwcfglink/.config/powershell/powershell.config.json")? != "/root/cw-secret.config.json" { return Err("the planted configuration-file symlink was replaced or removed") }
    if fs::read("/root/cw-secret.config.json")? != "{{\"CwSecret\":1}}" { return Err("the configuration-file symlink's target was changed") }
    if fs::read_link("/cwcfgdir/.config/powershell")? != "/root/cw-protected-cfg" { return Err("the planted configuration-directory symlink was replaced or removed") }
    if fs::read("/root/cw-protected-cfg/powershell.config.json")? != "{{\"CwSecret\":1}}" { return Err("a configuration file was written through the symlinked directory") }

    // log_setting writes the lists as the comma-separated strings PowerShell
    // parses — a JSON array is not read at all.
    if at(doc, ["LogLevel"]).as_string().unwrap_or("") != "Informational" { return Ok(false) }
    if at(doc, ["LogIdentity"]).as_string().unwrap_or("") != "cwtest" { return Ok(false) }
    let channels = at(doc, ["LogChannels"]).as_string().unwrap_or("")
    if channels != "Operational, Analytic" { return Err("LogChannels is not the expected string: " + json::to_string(at(doc, ["LogChannels"]))) }
    let keywords = at(doc, ["LogKeywords"]).as_string().unwrap_or("")
    if keywords != "Runspace, Pipeline" { return Err("LogKeywords is not the expected string: " + json::to_string(at(doc, ["LogKeywords"]))) }

    // And PowerShell itself reads every one of them back, through the same
    // internal configuration reader it logs with. -SettingsFile points its
    // all-users file at the scratch one.
    let parsed = parsed_settings("/etc/cw/powershell.config.json")?
    if parsed != ["Informational", "True", "True", "cwtest", "RemoteSigned"] {
        return Err("PowerShell parsed the scratch configuration as " + parsed.join(" | ") + " (level, channels match, keywords match, identity, execution policy)")
    }
    Ok(true)
}
