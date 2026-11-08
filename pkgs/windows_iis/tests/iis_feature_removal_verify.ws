use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; if ((Get-WindowsFeature Web-Http-Redirect).Installed -or (Get-WindowsFeature Web-DAV-Publishing).Installed -or -not (Get-WindowsFeature Web-Dir-Browsing).Installed -or -not (Get-WindowsFeature Web-Server).Installed) {{ throw 'feature removal changed the wrong role services' }}", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(true)
}
