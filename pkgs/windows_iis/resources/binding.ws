use value
use json
use log
use common

// ---------------------------------------------------------------------------
// A site binding.
//
// IIS keys a binding on the whole (protocol, address, port, host header)
// tuple — that is literally what bindingInformation is — so changing a port
// adds a binding rather than editing one. Retire the old tuple with
// ensure = :absent.
//
// The certificate is attached with the binding object's AddSslCertificate
// rather than by writing certificateHash: that method also creates the
// HTTP.sys SSL binding, and a certificateHash written into configuration
// without it produces a site that looks right in IIS Manager and resets
// every TLS connection.
// ---------------------------------------------------------------------------

fn site_filter(params: Value) -> Result[string, string] {
    let site = common::param_str(params, "site", "")
    if site == "" { return Err("missing 'site' parameter") }
    Ok("system.applicationHost/sites/site[@name='" + common::xp(site)? + "']/bindings")
}

fn protocol(params: Value) -> Result[string, string] {
    let p = common::param_str(params, "protocol", "http")
    if p == "http" { return Ok("http") }
    if p == "https" { return Ok("https") }
    if p == "net_tcp" { return Ok("net.tcp") }
    if p == "net_pipe" { return Ok("net.pipe") }
    if p == "net_msmq" { return Ok("net.msmq") }
    if p == "msmq_formatname" { return Ok("msmq.formatname") }
    Err("invalid 'protocol' value '" + p + "'")
}

// address:port:hostheader, IIS's own spelling.
fn binding_information(params: Value) -> string {
    common::param_str(params, "ip", "*") + ":" + common::itoa(common::param_int(params, "port", 80)) + ":" +
        common::param_str(params, "host_header", "")
}

fn ssl_flags(params: Value) -> Result[int, string] {
    let f = common::param_str(params, "ssl_flags", "none")
    if f == "none" { return Ok(0) }
    if f == "sni" { return Ok(1) }
    if f == "central_cert_store" { return Ok(2) }
    if f == "sni_central_cert_store" { return Ok(3) }
    Err("invalid 'ssl_flags' value '" + f + "'")
}

// Thumbprints are compared without separators or case: the store hands them
// back as unbroken uppercase hex, but people paste them out of certmgr with
// spaces in.
fn norm_thumb(t: string) -> string {
    t.replace(" ", "").replace(":", "").to_upper()
}

// 'ABSENT', or { ssl_flags, certificate_hash }.
fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$b = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(site_filter(params)? + "/binding") + " | Where-Object {{ " +
        "[string]$_.protocol -eq " + common::ps_q(protocol(params)?) + " -and " +
        "[string]$_.bindingInformation -eq " + common::ps_q(binding_information(params)) + " }}); " +
        "if ($b.Count -eq 0) {{ 'ABSENT' }} else {{ " +
        // certificateHash is a byte[] on an https binding and absent or
        // empty on any other, so the hex is only built when it really is one.
        "$h = $b[0].GetAttributeValue('certificateHash'); $hex = ''; " +
        "if ($h -is [byte[]]) {{ $hex = (($h | ForEach-Object {{ $_.ToString('X2') }}) -join '') }} " +
        "elseif ($null -ne $h) {{ $hex = [string]$h }}; " +
        "[pscustomobject]@{{ ssl_flags = [string]$b[0].GetAttributeValue('sslFlags'); " +
        "certificate_hash = $hex }} | ConvertTo-Json -Compress }}")
}

fn wants_certificate(params: Value) -> bool {
    common::param_str(params, "certificate_thumbprint", "") != "" ||
        common::param_str(params, "certificate_subject", "") != ""
}

// The thumbprint the step asks for: the one it named, or the newest unexpired
// certificate in the store whose subject matches. Empty when the step named
// none, and empty when it named a subject the store does not hold yet — a
// check runs before any step applies, so the certificate a sibling step is
// about to create is legitimately missing at that point.
fn wanted_thumb(params: Value) -> Result[string, string] {
    let thumb = common::param_str(params, "certificate_thumbprint", "")
    if thumb != "" { return Ok(norm_thumb(thumb)) }
    let subject = common::param_str(params, "certificate_subject", "")
    if subject == "" { return Ok("") }
    let store = common::param_str(params, "certificate_store", "My")
    let found = common::ps_out(
        "$c = @(Get-ChildItem -Path " + common::ps_q("Cert:\\LocalMachine\\" + store) +
        " | Where-Object {{ $_.Subject -eq " + common::ps_q(subject) + " -and $_.NotAfter -gt (Get-Date) }} | " +
        "Sort-Object NotAfter -Descending); " +
        "if ($c.Count -eq 0) {{ '' }} else {{ $c[0].Thumbprint }}")?
    if found == "" { return Ok("") }
    Ok(norm_thumb(found))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let b = json::parse(st)?
    if common::get_str(b, "ssl_flags") != common::itoa(ssl_flags(params)?) { return Ok(CheckResult::NotConfigured) }
    let want = wanted_thumb(params)?
    // The certificate the step named is not in the store yet, so the binding
    // cannot be right. apply says why.
    if wants_certificate(params) && want == "" { return Ok(CheckResult::NotConfigured) }
    if want != "" && norm_thumb(common::get_str(b, "certificate_hash")) != want {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let st = probe(params)?
    let filter = common::ps_q(site_filter(params)?)
    let proto = protocol(params)?
    let info = binding_information(params)
    let at = "@{{protocol=" + common::ps_q(proto) + "; bindingInformation=" + common::ps_q(info) + "}}"
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing " + proto + " binding " + info)
        common::ps_run("Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -AtElement " + at)?
        return Ok(ApplyResult::Success)
    }
    let flags = ssl_flags(params)?
    if st == "ABSENT" {
        log::info("adding " + proto + " binding " + info)
        common::ps_run("Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -Value @{{protocol=" + common::ps_q(proto) +
            "; bindingInformation=" + common::ps_q(info) + "; sslFlags=" + common::itoa(flags) + "}}")?
    } else {
        let b = json::parse(st)?
        if common::get_str(b, "ssl_flags") != common::itoa(flags) {
            common::ps_run("Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                common::ps_q(site_filter(params)? + "/binding[@protocol='" + common::xp(proto)? +
                    "'][@bindingInformation='" + common::xp(info)? + "']") +
                " -Name 'sslFlags' -Value " + common::itoa(flags))?
        }
    }
    let want = wanted_thumb(params)?
    if want == "" {
        if !wants_certificate(params) { return Ok(ApplyResult::Success) }
        return Err("no unexpired certificate with subject '" +
            common::param_str(params, "certificate_subject", "") + "' in LocalMachine\\" +
            common::param_str(params, "certificate_store", "My"))
    }
    let now = probe(params)?
    if now != "ABSENT" && norm_thumb(common::get_str(json::parse(now)?, "certificate_hash")) == want {
        return Ok(ApplyResult::Success)
    }
    log::info("attaching certificate " + want + " to " + proto + " binding " + info)
    common::ps_run(
        "$b = Get-WebBinding -Name " + common::ps_q(common::param_str(params, "site", "")) +
        " -Protocol " + common::ps_q(proto) + " -Port " + common::itoa(common::param_int(params, "port", 80)) +
        " -HostHeader " + common::ps_q(common::param_str(params, "host_header", "")) + "; " +
        "$b.AddSslCertificate(" + common::ps_q(want) + ", " +
        common::ps_q(common::param_str(params, "certificate_store", "My")) + ")")?
    Ok(ApplyResult::Success)
}
