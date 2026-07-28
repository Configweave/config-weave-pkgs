use value
use fs
use shell
use json

fn at(doc: Value, keys: List[string]) -> Value {
    let cur = doc
    for k in keys {
        if let Some(next) = cur.get(k) { cur = next } else { return Value::Null }
    }
    cur
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

    // log_setting
    if at(doc, ["LogLevel"]).as_string().unwrap_or("") != "Informational" { return Ok(false) }
    if at(doc, ["LogIdentity"]).as_string().unwrap_or("") != "cwtest" { return Ok(false) }
    let keywords: List[string] = []
    if let Some(items) = at(doc, ["LogKeywords"]).as_list() {
        for item in items { keywords.push(item.as_string().unwrap_or("")) }
    }
    if keywords != ["Runspace", "Pipeline"] { return Ok(false) }

    Ok(true)
}
