use value
use log
use common

// ---------------------------------------------------------------------------
// A self-signed certificate for a set of DNS names.
//
// It converges on "the store holds an unexpired certificate for these names",
// not on "create a certificate". A resource that minted one every run would
// leave a pile of certificates behind and move the thumbprint out from under
// every binding pointing at it. renew_before is what turns that into a
// rollover: once the certificate is inside that window of expiring, the next
// run replaces it.
// ---------------------------------------------------------------------------

fn store_path(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "store", "my")
    if s == "my" { return Ok("Cert:\\LocalMachine\\My") }
    if s == "web_hosting" { return Ok("Cert:\\LocalMachine\\WebHosting") }
    Err("invalid 'store' value '" + s + "' (expected :my or :web_hosting)")
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
    Ok("$_.Subject -eq " + common::ps_q(subject(params)?))
}

// Certificates matching the subject that are still valid for at least
// renew_before.
fn live_count(params: Value) -> Result[int, string] {
    let renew_secs = common::param_int(params, "renew_before", 0) / 1000000000
    let out = common::ps_out("@(Get-ChildItem -Path " + common::ps_q(store_path(params)?) +
        " | Where-Object {{ " + matcher(params)? + " -and $_.NotAfter -gt (Get-Date).AddSeconds(" +
        common::itoa(renew_secs) + ") }}).Count")?
    if let Some(n) = out.parse_int() { return Ok(n) }
    Err("could not read the certificate store: " + out)
}

fn any_count(params: Value) -> Result[int, string] {
    let out = common::ps_out("@(Get-ChildItem -Path " + common::ps_q(store_path(params)?) +
        " | Where-Object {{ " + matcher(params)? + " }}).Count")?
    if let Some(n) = out.parse_int() { return Ok(n) }
    Err("could not read the certificate store: " + out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if common::want_present(params)? {
        if live_count(params)? > 0 { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if any_count(params)? > 0 { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let store = store_path(params)?
    if !common::want_present(params)? {
        if any_count(params)? == 0 { return Ok(ApplyResult::Success) }
        // -DeleteKey, not -Force: Remove-Item ignores -Force in the Cert:
        // drive, so without it every renewal orphaned a private key blob. It
        // needs an explicit -Path: -DeleteKey is a dynamic parameter of the
        // certificate provider and does not bind through a pipe.
        log::info("removing self-signed certificates for " + subject(params)?)
        common::ps_run("Get-ChildItem -Path " + common::ps_q(store) + " | Where-Object {{ " + matcher(params)? +
            " }} | ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}")?
        return Ok(ApplyResult::Success)
    }
    if live_count(params)? > 0 { return Ok(ApplyResult::Success) }
    let names: List[string] = []
    for n in dns_names(params)? { names.push(common::ps_q(n)) }
    let friendly = common::param_str(params, "friendly_name", "")
    let friendly_arg = if friendly == "" { "" } else { " -FriendlyName " + common::ps_q(friendly) }
    log::info("creating a self-signed certificate for " + subject(params)?)
    // New-SelfSignedCertificate only accepts Cert:\\CurrentUser\\My or
    // Cert:\\LocalMachine\\My — it documents no other store — so a certificate
    // destined for WebHosting is created in My and then moved with an
    // export/import round trip. Move-Item cannot be used: it relocates the
    // certificate but not its private key.
    let create = "New-SelfSignedCertificate -DnsName " + names.join(",") +
        " -CertStoreLocation 'Cert:\\LocalMachine\\My'" +
        " -KeyLength " + common::itoa(common::param_int(params, "key_length", 2048)) +
        " -NotAfter (Get-Date).AddDays(" + common::itoa(common::param_int(params, "valid_days", 365)) + ")" +
        friendly_arg
    // Any predecessor goes first, so the store does not accumulate one dead
    // certificate per renewal.
    let purge = "Get-ChildItem -Path " + common::ps_q(store) + " | Where-Object {{ " + matcher(params)? +
        " }} | ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}; "
    if store == "Cert:\\LocalMachine\\My" {
        common::ps_run(purge + create + " | Out-Null")?
        return Ok(ApplyResult::Success)
    }
    common::ps_run(
        purge +
        "Get-ChildItem -Path 'Cert:\\LocalMachine\\My' | Where-Object {{ " + matcher(params)? +
        " }} | ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}; " +
        "$c = " + create + "; " +
        "$pfx = Join-Path $env:TEMP ('cw-' + $c.Thumbprint + '.pfx'); " +
        "$pw = ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force; " +
        "Export-PfxCertificate -Cert $c -FilePath $pfx -Password $pw | Out-Null; " +
        "Import-PfxCertificate -FilePath $pfx -CertStoreLocation " + common::ps_q(store) +
        " -Password $pw -Exportable | Out-Null; " +
        "Remove-Item -LiteralPath $pfx -Force; " +
        "Get-ChildItem -Path 'Cert:\\LocalMachine\\My' | " +
        "Where-Object {{ $_.Thumbprint -eq $c.Thumbprint }} | " +
        "ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}")?
    Ok(ApplyResult::Success)
}
