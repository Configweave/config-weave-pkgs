use value
use shell
use fs
use log

// Every removal step's own check() says the object is gone from the
// configuration; this asserts the side effects a removal must also undo — the
// HTTP.sys certificate binding, the certificate's private key, the module's
// DLL — and reads the configuration once more from a fresh process.

fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; " +
        "function T($ok, $what) {{ if ($ok) {{ 'ok ' + $what }} else {{ 'FAIL ' + $what }} }}; " +
        "Add-Type -Path (Join-Path $env:windir 'system32\\inetsrv\\Microsoft.Web.Administration.dll'); " +
        "$sm = New-Object Microsoft.Web.Administration.ServerManager; " +
        "T ($null -eq $sm.Sites['weave-site']) 'weave-site is gone'; " +
        "T ($null -eq $sm.ApplicationPools['weave-pool']) 'weave-pool is gone'; " +
        "$ssl = (netsh http show sslcert ipport=0.0.0.0:8443) -join ' '; " +
        "T (-not ($ssl -match 'Certificate Hash')) 'no HTTP.sys certificate binding is left on 0.0.0.0:8443'; " +
        "$lo = (netsh http show sslcert ipport=127.0.0.1:8443) -join ' '; " +
        "T (-not ($lo -match 'Certificate Hash')) 'removing the site removed the 127.0.0.1:8443 certificate binding'; " +
        "$sni = (netsh http show sslcert hostnameport=weave-renew.local:8444) -join ' '; " +
        "T (-not ($sni -match 'Certificate Hash')) 'removing the site removed the weave-renew.local:8444 certificate binding'; " +
        "T (@(Get-ChildItem Cert:\\LocalMachine\\My | Where-Object {{ $_.Subject -eq 'CN=weave-pfx.local' }}).Count -eq 0) 'the imported certificate is gone'; " +
        "T (@(Get-ChildItem Cert:\\LocalMachine\\WebHosting | Where-Object {{ $_.Subject -eq 'CN=weave-wh.local' }}).Count -eq 0) 'the WebHosting certificate is gone'; " +
        "$cfg = $sm.GetApplicationHostConfiguration(); " +
        "T (@($cfg.GetSection('system.webServer/globalModules').GetCollection() | Where-Object {{ $_['name'] -eq 'WeaveGlobalModule' }}).Count -eq 0) 'WeaveGlobalModule is unregistered'; " +
        "T (@($cfg.GetSection('system.webServer/httpCompression').GetCollection() | Where-Object {{ $_['name'] -eq 'weave-deflate' }}).Count -eq 0) 'weave-deflate is unregistered'; " +
        "T (@($cfg.GetSection('system.webServer/fastCgi').GetCollection() | Where-Object {{ $_['fullPath'] -eq 'C:\\weave-iis\\fcgi\\weave-fcgi.exe' }}).Count -eq 0) 'the FastCGI application is gone'; " +
        "T (@($cfg.GetSection('system.applicationHost/applicationPools').GetCollection()).Count -gt 0) 'the remaining configuration still reads'; " +
        "T ((Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\IIS\\CentralCertProvider).Enabled -eq 0) 'the central certificate store is disabled'",
        Value::Null)?
    if !out.success {
        log::warn("removal checks failed: " + out.stderr.trim())
        return Ok(false)
    }
    let ok = true
    for line in out.stdout.trim().split("\n") {
        let l = line.trim()
        if l.starts_with("FAIL") { log::warn(l); ok = false }
    }
    if fs::exists("C:\\Windows\\System32\\inetsrv\\rewrite.dll") {
        log::warn("rewrite.dll is still installed")
        ok = false
    }
    Ok(ok)
}
