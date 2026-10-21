use value
use log
use fs
use http
use hash
use common

// ---------------------------------------------------------------------------
// A PFX imported into a LocalMachine certificate store.
//
// Identity is the thumbprint when one is given — the only identity that
// cannot match the wrong certificate — and the subject otherwise. An import
// only happens when nothing already matches, so re-running never produces a
// second copy and never rotates a certificate a binding is pointing at.
//
// Removal by subject alone refuses when more than one certificate matches:
// a subject is not unique, and the others may be CA-issued certificates
// another site is serving.
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
    let out = common::ps_out("@(Get-ChildItem -LiteralPath " + common::ps_q(store_path(params)?) +
        " | Where-Object {{ " + matcher(params)? + " }}).Count")?
    if let Some(n) = out.parse_int() { return Ok(n) }
    Err("could not read the certificate store: " + out)
}

// :absent identified by subject only removes a certificate it can name
// unambiguously.
fn removable(params: Value) -> Result[int, string] {
    let n = count(params)?
    if n > 1 && common::param_str(params, "thumbprint", "") == "" {
        return Err(common::itoa(n) + " certificates have subject '" + common::param_str(params, "subject", "") +
            "'; give 'thumbprint' to say which one to remove")
    }
    Ok(n)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if !common::want_present(params)? {
        if removable(params)? > 0 { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let there = count(params)? > 0
    if common::want_present(params)? {
        if there { return Ok(CheckResult::AlreadyConfigured) }
        if common::param_str(params, "pfx_path", "") == "" {
            return Err("no matching certificate in the store and no 'pfx_path' was given to import one")
        }
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let store = store_path(params)?
    if !common::want_present(params)? {
        if removable(params)? == 0 { return Ok(ApplyResult::Success) }
        // -DeleteKey, not -Force: in the Cert: drive Remove-Item honours only
        // DeleteKey/Path/WhatIf/Confirm and IGNORES everything else, so -Force
        // did nothing and the private key was left behind in MachineKeys.
        // It has to be passed with an explicit -Path: -DeleteKey is a dynamic
        // parameter of the certificate provider, and piping gives PowerShell no
        // path to resolve it against.
        log::info("removing certificate from " + store)
        common::ps_run("Get-ChildItem -LiteralPath " + common::ps_q(store) + " | Where-Object {{ " + matcher(params)? +
            " }} | ForEach-Object {{ Remove-Item -LiteralPath $_.PSPath -DeleteKey }}")?
        return Ok(ApplyResult::Success)
    }
    if count(params)? > 0 { return Ok(ApplyResult::Success) }
    let source = common::param_str(params, "pfx_path", "")
    if source == "" {
        return Err("no matching certificate in the store and no 'pfx_path' was given to import one")
    }
    let want_sha = common::param_str(params, "sha256", "").to_lower()
    // A URL is fetched host-side so the guest needs no network stack of its
    // own, the same way windows_installers.msi_package handles a remote MSI.
    // The download is a temporary copy of a private key, so it is deleted
    // whether or not the import succeeds.
    let remote = source.starts_with("http://") || source.starts_with("https://")
    let local = source
    // http::download checks a download against `sha256` itself, so import
    // only hashes a local file.
    if remote {
        local = fs::temp_file()?
        log::info("downloading " + source)
        let o = #{ "retries": Value::Int(3) }
        if want_sha != "" { o.insert("sha256", Value::String(want_sha)) }
        if let Err(e) = http::download(source, local, Value::Map(o)) {
            fs::delete(local).unwrap_or(())
            return Err(e)
        }
    }
    let result = import(params, store, local, if remote { "" } else { want_sha })
    if remote { fs::delete(local).unwrap_or(()) }
    result?
    // Import-PfxCertificate succeeds on any valid PFX, whatever it holds, so
    // the store is asked again: the step is only done if the certificate it
    // names arrived.
    if count(params)? == 0 {
        return Err("imported " + source + " but the store still holds no certificate matching " + matcher(params)?)
    }
    Ok(ApplyResult::Success)
}

fn import(params: Value, store: string, local: string, want_sha: string) -> Result[unit, string] {
    if want_sha != "" {
        let got = hash::sha256_file(local)?.to_lower()
        if got != want_sha {
            return Err("sha256 of " + common::param_str(params, "pfx_path", "") + " is " + got + ", expected " + want_sha)
        }
    }
    let password = common::param_str(params, "password", "")
    // The password travels in the environment, never in the script text.
    let pw = if password == "" { "" } else { " -Password (ConvertTo-SecureString $env:CW_SECRET -AsPlainText -Force)" }
    let exportable = if common::param_bool(params, "exportable", false) { " -Exportable" } else { "" }
    log::info("importing certificate into " + store)
    common::ps_run_env("Import-PfxCertificate -FilePath " + common::ps_q(local) + " -CertStoreLocation " +
        common::ps_q(store) + pw + exportable + " | Out-Null", common::secret_env(password))
}
