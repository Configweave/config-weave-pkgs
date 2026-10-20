use value
use json
use common

fn verify(facts: Value) -> Result[bool, string] {
    // The shim answers for SYSTEM through cmd, as a script calling `winget`
    // would reach it.
    let script = "$v = (& cmd.exe /c 'winget --version' | Select-Object -First 1)\n" +
        "$shim = [IO.File]::ReadAllText((Join-Path $env:SystemRoot 'System32\\winget.cmd'))\n" +
        "$prov = @(Get-AppxProvisionedPackage -Online | Where-Object {{ $_.DisplayName -eq 'Microsoft.DesktopAppInstaller' }}).Count\n" +
        common::winget_ps() +
        "$f = Join-Path ([IO.Path]::GetTempPath()) 'cw-verify.json'\n" +
        "$null = & $winget export --output $f --include-versions --accept-source-agreements --disable-interactivity\n" +
        "$p = @{{}}\n" +
        "foreach ($s in @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).Sources)) {{ foreach ($x in @($s.Packages)) {{ $p[$x.PackageIdentifier] = [string]$x.Version }} }}\n" +
        // winget list exits 0 when the filter matches nothing on an installed
        // package, so what counts is whether the id is in the table.
        "$up = @(@(& $winget list --exact --id 7zip.7zip --upgrade-available --source winget --accept-source-agreements --disable-interactivity) -match '7zip\\.7zip').Count\n" +
        "$jq = @(@(& $winget list --exact --id jqlang.jq --scope machine --accept-source-agreements --disable-interactivity) -match 'jqlang\\.jq').Count\n" +
        "ConvertTo-Json -Compress @{{ version = [string]$v; shim = $shim; provisioned = $prov; sevenzip = [string]$p['7zip.7zip']; upgrade = $up; jq = $jq; pwsh = (Test-Path 'C:\\Program Files\\PowerShell\\7\\pwsh.exe') }}\n"
    let out = common::query(script, #{})?
    if !out.success { return Err(common::failure("reading winget state", out)) }
    let s = json::parse(out.stdout.trim())?
    let v = common::get_str(s, "version")
    if !common::version_ok(v, "1.20", true) { return Err("`winget --version` through the shim printed '" + v + "', expected at least 1.20") }
    if !common::get_str(s, "shim").contains("config-weave windows_packages.winget_installed") { return Err("the shim carries no marker") }
    if common::get_int(s, "provisioned") < 1 { return Err("App Installer is not provisioned for all users") }
    let z = common::get_str(s, "sevenzip")
    if z == "" || common::version_cmp(z, "24.08") <= 0 { return Err("7zip.7zip is '" + z + "', expected an upgrade from 24.08") }
    if common::get_int(s, "upgrade") != 0 { return Err("winget still lists an upgrade for 7zip.7zip") }
    if common::get_int(s, "jq") == 0 { return Err("jqlang.jq is not installed at machine scope") }
    if !common::get_bool(s, "pwsh") { return Err("Microsoft.PowerShell did not install its MSI into C:\\Program Files\\PowerShell\\7") }
    Ok(true)
}
