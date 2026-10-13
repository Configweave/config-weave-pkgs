use value
use shell
use log

// What the steps' own check() cannot see: that the patched rewrite rule kept
// its place and still rewrites, that both mask entries exist side by side,
// that TLS is now required on /tls, and that the renewed certificate is the
// one HTTP.sys serves.

fn curl(args: string) -> Result[CmdOutput, string] {
    shell::run("curl.exe --silent --show-error --insecure --max-time 30 " + args, Value::Null)
}

fn status(url: string) -> Result[string, string] {
    let out = curl("--output NUL --write-out %{{http_code}} " + url)?
    if !out.success { return Err("curl " + url + " failed: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

// Each check prints one line, "ok <what>" or "FAIL <what>".
fn config_checks() -> Result[List[string], string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; Import-Module WebAdministration; " +
        "function T($ok, $what) {{ if ($ok) {{ 'ok ' + $what }} else {{ 'FAIL ' + $what }} }}; " +
        "$rules = @((Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Location 'weave-site' -Filter 'system.webServer/rewrite/rules').Collection); " +
        "T ($rules.Count -gt 0 -and [string]$rules[0].name -eq 'weave-rewrite') 'weave-rewrite is still the first rule'; " +
        "$ips = @((Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Location 'weave-site/secure' -Filter 'system.webServer/security/ipSecurity').Collection | " +
        "Where-Object {{ [string]$_.ipAddress -eq '127.0.0.1' }}); " +
        "T ($ips.Count -eq 2) 'both 127.0.0.1 entries exist'; " +
        "$renew = @(Get-ChildItem Cert:\\LocalMachine\\My | Where-Object {{ $_.Subject -eq 'CN=weave-renew.local' }}); " +
        "T ($renew.Count -eq 1 -and $renew[0].NotAfter -gt (Get-Date).AddDays(20)) 'one renewed weave-renew.local certificate'; " +
        "$sni = @(Get-ChildItem IIS:\\SslBindings | Where-Object {{ [string]$_.Host -eq 'weave-renew.local' -and [string]$_.Port -eq '8444' }}); " +
        "T ($sni.Count -eq 1 -and $renew.Count -eq 1 -and [string]$sni[0].Thumbprint -eq $renew[0].Thumbprint) 'the SNI binding serves the renewed certificate'; " +
        "$ipb = @(Get-ChildItem IIS:\\SslBindings | Where-Object {{ [string]$_.Port -eq '8443' }}); " +
        "$main = @(Get-ChildItem Cert:\\LocalMachine\\My | Where-Object {{ $_.Subject -eq 'CN=weave.local' }}); " +
        "T (@($ipb | Where-Object {{ [string]$_.IPAddress -eq '127.0.0.1' -and $renew.Count -eq 1 -and [string]$_.Thumbprint -eq $renew[0].Thumbprint }}).Count -eq 1) '127.0.0.1:8443 serves the weave-renew.local certificate'; " +
        "T (@($ipb | Where-Object {{ [string]$_.IPAddress -eq '0.0.0.0' -and $main.Count -eq 1 -and [string]$_.Thumbprint -eq $main[0].Thumbprint }}).Count -eq 1) '0.0.0.0:8443 still serves weave.local'; " +
        "T (@(Get-ChildItem Cert:\\LocalMachine\\WebHosting | Where-Object {{ $_.Subject -eq 'CN=weave-wh.local' }}).Count -eq 1) 'the WebHosting certificate exists'; " +
        "T ((Get-Content -Raw C:\\weave-iis\\pipeline\\web.config) -match 'X-Weave-Pipeline') 'the header is in /pipeline/web.config'; " +
        "$ccs = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\IIS\\CentralCertProvider; " +
        "T ($ccs.Enabled -eq 1 -and $ccs.CertStoreLocation -eq 'C:\\weave-iis\\ccs' -and $ccs.UserName -eq 'weave-ccs') 'the central certificate store is enabled'; " +
        "T ([string](Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter \"system.applicationHost/sites/site[@name='weave-site']\" -Name id).Value -eq '42') 'weave-site is id 42'",
        Value::Null)?
    if !out.success { return Err("config checks failed: " + out.stderr.trim()) }
    Ok(out.stdout.trim().split("\n"))
}

fn verify(facts: Value) -> Result[bool, string] {
    let ok = true
    for line in config_checks()? {
        let l = line.trim()
        if l.starts_with("FAIL") { log::warn(l); ok = false }
    }
    // The patched rule still rewrites: the new condition matches localhost.
    let rewritten = curl("http://localhost:8080/old/index.html")?
    if !rewritten.stdout.contains("weave-rewritten") {
        log::warn("/old/index.html is no longer rewritten after the rule was patched")
        ok = false
    }
    let plain = status("http://localhost:8080/tls/")?
    if plain != "403" {
        log::warn("expected 403 from /tls over HTTP, got " + plain)
        ok = false
    }
    let tls = curl("https://localhost:8443/tls/")?
    if !tls.stdout.contains("weave-tls-ok") {
        log::warn("/tls did not serve over HTTPS")
        ok = false
    }
    Ok(ok)
}
