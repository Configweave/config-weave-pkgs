use value
use json
use common

fn verify(facts: Value) -> Result[bool, string] {
    let script = "$v = (& cmd.exe /c 'winget --version' | Select-Object -First 1)\n" +
        "$prov = @(Get-AppxProvisionedPackage -Online | Where-Object {{ $_.DisplayName -eq 'Microsoft.DesktopAppInstaller' }}).Count\n" +
        "ConvertTo-Json -Compress @{{ version = [string]$v; provisioned = $prov }}\n"
    let out = common::query(script, #{})?
    if !out.success { return Err(common::failure("reading winget state", out)) }
    let s = json::parse(out.stdout.trim())?
    let v = common::get_str(s, "version")
    if !v.starts_with("v1.") { return Err("`winget --version` through the shim printed '" + v + "'") }
    if common::get_int(s, "provisioned") < 1 { return Err("App Installer is not provisioned") }
    Ok(true)
}
