use value
use json
use log
use common

// ---------------------------------------------------------------------------
// A self-signed certificate for a set of DNS names.
//
// It converges on "the store holds an unexpired self-signed certificate for
// exactly these names", not on "create a certificate". A resource that minted
// one every run would leave a pile of certificates behind and move the
// thumbprint out from under every binding pointing at it. renew_before is
// what turns that into a rollover: once the certificate is inside that window
// of expiring, the next run replaces it.
//
// Only self-signed certificates (Issuer equal to Subject) are ever matched,
// so a CA-issued certificate for the same name is never touched. A
// replacement — renewal, or a change of dns_names or key_length — is created
// first; every https binding using the old thumbprint is moved to the new
// one; only then are the old certificates deleted.
// ---------------------------------------------------------------------------

fn store_name(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "store", "my")
    if s == "my" { return Ok("My") }
    if s == "web_hosting" { return Ok("WebHosting") }
    Err("invalid 'store' value '" + s + "' (expected :my or :web_hosting)")
}

fn store_path(params: Value) -> Result[string, string] {
    Ok("Cert:\\LocalMachine\\" + store_name(params)?)
}

fn dns_names(params: Value) -> Result[List[string], string] {
    let names = common::param_list(params, "dns_names")
    if names.is_empty() { return Err("'dns_names' must name at least one host") }
    Ok(names)
}

// New-SelfSignedCertificate builds the subject from the first DNS name, so
// that is what identifies the certificate afterwards.
fn subject(params: Value) -> Result[string, string] {
    Ok("CN=" + dns_names(params)?.get(0).unwrap_or(""))
}

fn matcher(params: Value) -> Result[string, string] {
    Ok("$_.Subject -eq " + common::ps_q(subject(params)?) + " -and $_.Issuer -eq $_.Subject")
}

fn renew_secs(params: Value) -> int { common::param_int(params, "renew_before", 0) / 1000000000 }

// A certificate valid for no longer than renew_before is inside its renewal
// window the moment it is created, so every run would replace it.
fn validate(params: Value) -> Result[unit, string] {
    store_name(params)?
    dns_names(params)?
    let days = common::param_int(params, "valid_days", 365)
    if days < 1 { return Err("'valid_days' must be at least 1") }
    if days * 86400 <= renew_secs(params) {
        return Err("'valid_days' (" + common::itoa(days) + ") must be longer than 'renew_before', or every run replaces the certificate")
    }
    Ok(())
}

fn as_items(v: Value) -> List[Value] {
    let out: List[Value] = []
    if let Some(items) = v.as_list() {
        for item in items { out.push(item) }
    } else if let Some(single) = v.as_map() {
        out.push(Value::Map(single))
    }
    out
}

// One { thumb, fresh, dns, keysize, friendly } map per matching certificate:
// fresh is "valid for longer than renew_before", dns the lowercased DNS
// names, comma-joined in the certificate's order.
fn probe(params: Value) -> Result[List[Value], string] {
    let raw = common::ps_out(
        "$now = (Get-Date).AddSeconds(" + common::itoa(renew_secs(params)) + "); " +
        "$out = @(Get-ChildItem -LiteralPath " + common::ps_q(store_path(params)?) +
        " | Where-Object {{ " + matcher(params)? + " }} | ForEach-Object {{ " +
        "$ks = 0; try {{ $ks = [int]$_.PublicKey.Key.KeySize }} catch {{ }}; " +
        "[pscustomobject]@{{ thumb = [string]$_.Thumbprint; fresh = [string]($_.NotAfter -gt $now); " +
        "dns = ((@($_.DnsNameList | ForEach-Object {{ ([string]$_.Unicode).ToLower() }})) -join ','); " +
        "keysize = [string]$ks; friendly = [string]$_.FriendlyName }} }}); " +
        "ConvertTo-Json -InputObject @($out) -Compress")?
    if raw == "" || raw == "null" { return Ok([]) }
    Ok(as_items(json::parse(raw)?))
}

fn same_names(have: string, want: List[string]) -> bool {
    let h: List[string] = []
    for n in have.split(",") { if n != "" && !h.contains(n) { h.push(n) } }
    let w: List[string] = []
    for n in want { let l = n.to_lower(); if !w.contains(l) { w.push(l) } }
    if h.len() != w.len() { return false }
    for n in w { if !h.contains(n) { return false } }
    true
}

// The thumbprint of a certificate that needs no replacement, or "".
fn live(params: Value, certs: List[Value]) -> Result[string, string] {
    let names = dns_names(params)?
    let bits = common::itoa(common::param_int(params, "key_length", 2048))
    for c in certs {
        if common::get_str(c, "fresh").to_lower() != "true" { continue }
        if !same_names(common::get_str(c, "dns"), names) { continue }
        let ks = common::get_str(c, "keysize")
        if ks != "0" && ks != "" && ks != bits { continue }
        return Ok(common::get_str(c, "thumb"))
    }
    Ok("")
}

fn friendly_of(certs: List[Value], thumb: string) -> string {
    for c in certs { if common::get_str(c, "thumb") == thumb { return common::get_str(c, "friendly") } }
    ""
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let certs = probe(params)?
    if !common::want_present(params)? {
        if certs.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let thumb = live(params, certs)?
    if thumb == "" { return Ok(CheckResult::NotConfigured) }
    let friendly = common::param_str(params, "friendly_name", "")
    if friendly != "" && friendly_of(certs, thumb) != friendly { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let store = store_path(params)?
    let certs = probe(params)?
    if !common::want_present(params)? {
        if certs.is_empty() { return Ok(ApplyResult::Success) }
        // -DeleteKey, not -Force: Remove-Item ignores -Force in the Cert:
        // drive, so without it every renewal orphaned a private key blob. It
        // needs an explicit path: -DeleteKey is a dynamic parameter of the
        // certificate provider and does not bind through a pipe.
        log::info("removing self-signed certificates for " + subject(params)?)
        common::ps_run("Get-ChildItem -LiteralPath " + common::ps_q(store) + " | Where-Object {{ " + matcher(params)? +
            " }} | ForEach-Object {{ Remove-Item -LiteralPath $_.PSPath -DeleteKey }}")?
        return Ok(ApplyResult::Success)
    }
    let friendly = common::param_str(params, "friendly_name", "")
    let thumb = live(params, certs)?
    if thumb != "" {
        if friendly != "" && friendly_of(certs, thumb) != friendly {
            log::info("setting the friendly name of " + thumb)
            common::ps_run("(Get-Item -LiteralPath " + common::ps_q(store + "\\" + thumb) + ").FriendlyName = " +
                common::ps_q(friendly))?
        }
        return Ok(ApplyResult::Success)
    }
    let names: List[string] = []
    for n in dns_names(params)? { names.push(common::ps_q(n)) }
    let friendly_arg = if friendly == "" { "" } else { " -FriendlyName " + common::ps_q(friendly) }
    let old: List[string] = []
    for c in certs { old.push(common::ps_q(common::get_str(c, "thumb"))) }
    log::info("creating a self-signed certificate for " + subject(params)?)
    // New-SelfSignedCertificate only accepts Cert:\CurrentUser\My or
    // Cert:\LocalMachine\My — it documents no other store — so a certificate
    // destined for WebHosting is created in My and then moved with an
    // export/import round trip. Move-Item cannot be used: it relocates the
    // certificate but not its private key.
    let create = "$c = New-SelfSignedCertificate -DnsName " + names.join(",") +
        " -CertStoreLocation 'Cert:\\LocalMachine\\My'" +
        " -KeyLength " + common::itoa(common::param_int(params, "key_length", 2048)) +
        " -NotAfter (Get-Date).AddDays(" + common::itoa(common::param_int(params, "valid_days", 365)) + ")" +
        friendly_arg + "; $new = $c.Thumbprint; "
    let relocate = if store_name(params)? == "My" { "" } else {
        "$pfx = Join-Path $env:TEMP ('cw-' + $new + '.pfx'); " +
        "$pw = ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force; " +
        "try {{ Export-PfxCertificate -Cert $c -FilePath $pfx -Password $pw | Out-Null; " +
        "Import-PfxCertificate -FilePath $pfx -CertStoreLocation " + common::ps_q(store) +
        " -Password $pw -Exportable | Out-Null }} finally {{ Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue }}; " +
        "Remove-Item -LiteralPath $c.PSPath -DeleteKey; "
    }
    // Bindings follow the certificate before the old one goes, so a renewal
    // never leaves an https binding pointing at a deleted certificate.
    let rebind = if old.is_empty() { "" } else {
        "$old = @(" + old.join(", ") + "); " +
        "foreach ($b in @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' " +
        "-Filter 'system.applicationHost/sites/site/bindings/binding' | Where-Object {{ [string]$_.protocol -eq 'https' }})) {{ " +
        "$h = $b.GetAttributeValue('certificateHash'); $hex = ''; " +
        "if ($h -is [byte[]]) {{ $hex = (($h | ForEach-Object {{ $_.ToString('X2') }}) -join '') }} elseif ($null -ne $h) {{ $hex = [string]$h }}; " +
        "if ($hex -ne '' -and $old -contains $hex) {{ try {{ $b.RemoveSslCertificate() }} catch {{ }}; " +
        "$b.AddSslCertificate($new, " + common::ps_q(store_name(params)?) + ") }} }}; " +
        "foreach ($t in $old) {{ Remove-Item -LiteralPath (Join-Path " + common::ps_q(store) + " $t) -DeleteKey }}; "
    }
    if !old.is_empty() { log::info("replacing " + common::itoa(old.len()) + " older certificate(s) and moving their bindings") }
    common::ps_run(create + relocate + rebind)?
    Ok(ApplyResult::Success)
}
