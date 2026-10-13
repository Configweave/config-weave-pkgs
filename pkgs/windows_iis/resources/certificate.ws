use value
use log
use fs
use http
use common

// ---------------------------------------------------------------------------
// A PFX imported into a LocalMachine certificate store.
//
// Identity is the thumbprint when one is given — the only identity that
// cannot match the wrong certificate — and the subject otherwise. An import
// only happens when nothing already matches, so re-running never produces a
// second copy and never rotates a certificate a binding is pointing at.
// ---------------------------------------------------------------------------

fn store_path(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "store", "my")
    if s == "my" { return Ok("Cert:\\LocalMachine\\My") }
    if s == "web_hosting" { return Ok("Cert:\\LocalMachine\\WebHosting") }
    Err("invalid 'store' value '" + s + "' (expected :my or :web_hosting)")
}

fn norm_thumb(t: string) -> string { t.replace(" ", "").replace(":", "").to_upper() }

// The Where-Object test that picks this resource's certificate out of the
// store.
fn matcher(params: Value) -> Result[string, string] {
    let thumb = common::param_str(params, "thumbprint", "")
    if thumb != "" {
        return Ok("$_.Thumbprint -eq " + common::ps_q(norm_thumb(thumb)))
    }
    let subject = common::param_str(params, "subject", "")
    if subject == "" {
        return Err("give either 'thumbprint' or 'subject' so the certificate can be identified")
    }
    Ok("$_.Subject -eq " + common::ps_q(subject))
}

fn count(params: Value) -> Result[int, string] {
    let out = common::ps_out("@(Get-ChildItem -Path " + common::ps_q(store_path(params)?) +
        " | Where-Object {{ " + matcher(params)? + " }}).Count")?
    if let Some(n) = out.parse_int() { return Ok(n) }
    Err("could not read the certificate store: " + out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let there = count(params)? > 0
    if common::want_present(params)? {
        if there { return Ok(CheckResult::AlreadyConfigured) }
        if common::param_str(params, "pfx_path", "") == "" {
            return Err("no matching certificate in the store and no 'pfx_path' was given to import one")
        }
        return Ok(CheckResult::NotConfigured)
    }
    if there { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let store = store_path(params)?
    if !common::want_present(params)? {
        if count(params)? == 0 { return Ok(ApplyResult::Success) }
        // -DeleteKey, not -Force: in the Cert: drive Remove-Item honours only
        // DeleteKey/Path/WhatIf/Confirm and IGNORES everything else, so -Force
        // did nothing and the private key was left behind in MachineKeys.
        // It has to be passed with an explicit -Path: -DeleteKey is a dynamic
        // parameter of the certificate provider, and piping gives PowerShell no
        // path to resolve it against.
        log::info("removing certificate from " + store)
        common::ps_run("Get-ChildItem -Path " + common::ps_q(store) + " | Where-Object {{ " + matcher(params)? +
            " }} | ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}")?
        return Ok(ApplyResult::Success)
    }
    if count(params)? > 0 { return Ok(ApplyResult::Success) }
    let source = common::param_str(params, "pfx_path", "")
    if source == "" {
        return Err("no matching certificate in the store and no 'pfx_path' was given to import one")
    }
    // A URL is fetched host-side so the guest needs no network stack of its
    // own, the same way windows_installers.msi_package handles a remote MSI.
    let local = if source.starts_with("http://") || source.starts_with("https://") {
        let tmp = fs::temp_file()?
        log::info("downloading " + source)
        http::download(source, tmp, Value::Null)?
        tmp
    } else {
        source
    }
    let password = common::param_str(params, "password", "")
    let pw = if password == "" {
        ""
    } else {
        " -Password (ConvertTo-SecureString " + common::ps_q(password) + " -AsPlainText -Force)"
    }
    let exportable = if common::param_bool(params, "exportable", false) { " -Exportable" } else { "" }
    log::info("importing certificate into " + store)
    common::ps_run("Import-PfxCertificate -FilePath " + common::ps_q(local) + " -CertStoreLocation " +
        common::ps_q(store) + pw + exportable + " | Out-Null")?
    Ok(ApplyResult::Success)
}
