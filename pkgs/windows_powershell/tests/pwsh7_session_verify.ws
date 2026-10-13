use value
use fs
use json
use shell
use path

fn endpoints() -> Result[Value, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "endpoints.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n$net = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-2')\n@(Get-PSSessionConfiguration | ForEach-Object {{ $sd = New-Object System.Security.AccessControl.CommonSecurityDescriptor($false, $false, [string]$_.SecurityDescriptorSddl); [pscustomobject]@{{ name = [string]$_.Name; enabled = ([string]$_.Enabled).ToLower() -eq 'true'; deny_network = @($sd.DiscretionaryAcl | Where-Object {{ [string]$_.AceQualifier -eq 'AccessDenied' -and $_.SecurityIdentifier -eq $net }}).Count -gt 0; max_mb = [string]$_.psmaximumreceiveddatasizepercommandmb }} }}) | ConvertTo-Json -Compress")?
    let out = shell::run("powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\"", Value::Null)
    fs::delete_dir(dir)?
    let result = out?
    if !result.success { return Err("listing session configurations failed: " + result.stderr.trim()) }
    json::parse(result.stdout.trim())
}

fn find(list: Value, name: string) -> Option[Value] {
    for item in list.as_list().unwrap_or([]) {
        if item.get("name").unwrap_or(Value::String("")).as_string().unwrap_or("").to_lower() == name.to_lower() { return Some(item) }
    }
    None
}

fn flag(v: Value, key: string) -> bool { v.get(key).unwrap_or(Value::Bool(false)).as_bool().unwrap_or(false) }

fn verify(facts: Value) -> Result[bool, string] {
    // PowerShell 7 reads its LocalMachine policy from $PSHOME, not the
    // ShellIds registry key Windows PowerShell uses.
    let config = "C:\\Program Files\\PowerShell\\7\\powershell.config.json"
    let doc = json::parse(fs::read(config)?)?
    let policy = doc.get("Microsoft.PowerShell:ExecutionPolicy").unwrap_or(Value::String("")).as_string().unwrap_or("")
    if policy != "AllSigned" { return Err("the PowerShell 7 machine execution policy in " + config + " is '" + policy + "'") }

    let list = endpoints()?
    let restricted = find(list, "cwtest.restricted")
    if restricted.is_none() { return Err("cwtest.restricted was not registered") }
    let r = restricted.unwrap()
    if !flag(r, "enabled") || !flag(r, "deny_network") { return Err("cwtest.restricted is not local-only") }
    if r.get("max_mb").unwrap_or(Value::String("")).as_string().unwrap_or("") != "20" { return Err("cwtest.restricted did not get its data size limit") }

    let drift = find(list, "cwtest.drift")
    if drift.is_none() { return Err("cwtest.drift disappeared") }
    if !flag(drift.unwrap(), "deny_network") { return Err("cwtest.drift is still open to remote connections") }

    if find(list, "cwtest.gone").is_some() { return Err("cwtest.gone was not unregistered") }
    if find(list, "cwtest.never").is_some() { return Err("the ghost :absent step registered an endpoint") }

    let winps = find(list, "microsoft.powershell")
    if winps.is_some() && flag(winps.unwrap(), "enabled") { return Err("the microsoft.powershell endpoint is still enabled") }
    Ok(true)
}
