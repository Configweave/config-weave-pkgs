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
// every TLS connection. For the same reason check() compares both the
// configured hash and the HTTP.sys binding, and removal deletes the HTTP.sys
// binding too unless another https binding still uses its endpoint.
//
// The binding is selected exactly, by protocol and bindingInformation, from
// the site's own binding collection. Get-WebBinding cannot do that: it
// ignores the IP address, treats an empty host header as "any", and takes a
// wildcard site name.
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

fn cert_store(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "certificate_store", "my")
    if s == "my" { return Ok("My") }
    if s == "web_hosting" { return Ok("WebHosting") }
    Err("invalid 'certificate_store' value '" + s + "' (expected :my or :web_hosting)")
}

// PowerShell that leaves the binding element in $b (or $null), read from the
// site's collection and matched exactly — case-insensitively, as IIS matches.
fn find_binding(params: Value) -> Result[string, string] {
    Ok("$b = $null; try {{ $b = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(site_filter(params)? + "/binding") + " | Where-Object {{ " +
        "[string]$_.protocol -eq " + common::ps_q(protocol(params)?) + " -and " +
        "[string]$_.bindingInformation -eq " + common::ps_q(binding_information(params)) + " }})[0] }} catch {{ }}; ")
}

// PowerShell that sets $sni, $ccs and $ep for the HTTP.sys endpoint the
// binding $b uses: host:port with SNI, ip:port without, and none with the
// central certificate store, which keeps no per-endpoint certificate.
// Then $shared counts the other https bindings, on any site, using $ep.
fn endpoint() -> string {
    "$fl = [int]$b.GetAttributeValue('sslFlags'); $sni = ($fl -band 1) -ne 0; $ccs = ($fl -band 2) -ne 0; " +
    "$bi = ([string]$b.bindingInformation).Split(':'); $ip = $bi[0]; if ($ip -eq '*' -or $ip -eq '') {{ $ip = '0.0.0.0' }}; " +
    "$port = $bi[1]; $hh = ($bi[2..($bi.Count - 1)] -join ':'); " +
    "$ep = CwEp $b; " +
    "$shared = @(CwHttps | Where-Object {{ -not ([string]$_.bindingInformation -eq [string]$b.bindingInformation -and " +
    "[string]$_.ItemXPath -eq [string]$b.ItemXPath) -and (CwEp $_) -eq $ep }}).Count; "
}

// 'ABSENT', or { info, ssl_flags, certificate_hash, sslcert, shared }:
// sslcert is the thumbprint HTTP.sys holds for the binding's endpoint ("" for
// none, "ccs" for the central certificate store), shared how many other https
// bindings use that endpoint.
fn probe(params: Value) -> Result[string, string] {
    common::ps_out(find_binding(params)? +
        "if ($null -eq $b) {{ 'ABSENT' }} else {{ " +
        // certificateHash is a byte[] or a hex string on an https binding and
        // absent or empty on any other, so both shapes are handled.
        "$h = $b.GetAttributeValue('certificateHash'); $hex = ''; " +
        "if ($h -is [byte[]]) {{ $hex = (($h | ForEach-Object {{ $_.ToString('X2') }}) -join '') }} " +
        "elseif ($null -ne $h) {{ $hex = [string]$h }}; " +
        "$sc = ''; $shared = 0; if ([string]$b.protocol -eq 'https') {{ " + endpoint() +
        "if ($ccs) {{ $sc = 'ccs' }} else {{ foreach ($x in @(Get-ChildItem IIS:\\SslBindings)) {{ " +
        "if ([string]$x.Port -ne $port) {{ continue }}; " +
        "if ($sni) {{ if ([string]$x.Host -eq $hh) {{ $sc = [string]$x.Thumbprint }} }} " +
        "elseif ([string]$x.Host -eq '' -and [string]$x.IPAddress -eq $ip) {{ $sc = [string]$x.Thumbprint }} }} }} }}; " +
        "[pscustomobject]@{{ info = [string]$b.bindingInformation; ssl_flags = [string][int]$b.GetAttributeValue('sslFlags'); " +
        "certificate_hash = $hex; sslcert = $sc; shared = [string]$shared }} | ConvertTo-Json -Compress }}")
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
    let found = common::ps_out(
        "$c = @(Get-ChildItem -LiteralPath " + common::ps_q("Cert:\\LocalMachine\\" + cert_store(params)?) +
        " | Where-Object {{ $_.Subject -eq " + common::ps_q(subject) + " -and $_.NotAfter -gt (Get-Date) }} | " +
        "Sort-Object NotAfter -Descending); " +
        "if ($c.Count -eq 0) {{ '' }} else {{ $c[0].Thumbprint }}")?
    if found == "" { return Ok("") }
    Ok(norm_thumb(found))
}

// Whether the binding's certificate is right in both places: the configured
// certificateHash and the HTTP.sys binding for its endpoint.
fn cert_ok(b: Value, want: string) -> bool {
    if norm_thumb(common::get_str(b, "certificate_hash")) != want { return false }
    let sc = common::get_str(b, "sslcert")
    sc == "ccs" || norm_thumb(sc) == want
}

fn check(params: Value) -> Result[CheckResult, string] {
    cert_store(params)?
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
    if want != "" && !cert_ok(b, want) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let store = cert_store(params)?
    let st = probe(params)?
    let filter = common::ps_q(site_filter(params)?)
    let proto = protocol(params)?
    let info = binding_information(params)
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        let b = json::parse(st)?
        let live = common::get_str(b, "info")
        let sc = common::get_str(b, "sslcert")
        // The HTTP.sys binding goes first, while the element that names its
        // endpoint still exists — unless another https binding shares it.
        if sc != "" && sc != "ccs" && common::get_str(b, "shared") == "0" {
            log::info("removing the HTTP.sys certificate binding for " + proto + " binding " + live)
            common::ps_run(find_binding(params)? + "CwDelSsl (CwEp $b)")?
        }
        log::info("removing " + proto + " binding " + live)
        common::ps_run("Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -AtElement @{{protocol=" + common::ps_q(proto) +
            "; bindingInformation=" + common::ps_q(live) + "}}")?
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
            log::info("setting sslFlags on " + proto + " binding " + info)
            common::ps_run("Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                common::ps_q(site_filter(params)? + "/binding[@protocol='" + common::xp(proto)? +
                    "'][@bindingInformation='" + common::xp(common::get_str(b, "info"))? + "']") +
                " -Name 'sslFlags' -Value " + common::itoa(flags))?
        }
    }
    let want = wanted_thumb(params)?
    if want == "" {
        if !wants_certificate(params) { return Ok(ApplyResult::Success) }
        return Err("no unexpired certificate with subject '" +
            common::param_str(params, "certificate_subject", "") + "' in LocalMachine\\" + store)
    }
    let now = json::parse(probe(params)?)?
    if cert_ok(now, want) { return Ok(ApplyResult::Success) }
    log::info("attaching certificate " + want + " to " + proto + " binding " + info)
    // An HTTP.sys binding already holding another certificate is removed
    // first: AddSslCertificate will not overwrite it.
    let sc = common::get_str(now, "sslcert")
    let clear = if sc != "" && sc != "ccs" && norm_thumb(sc) != want { "$b.RemoveSslCertificate(); " } else { "" }
    common::ps_run(find_binding(params)? + clear +
        "$b.AddSslCertificate(" + common::ps_q(want) + ", " + common::ps_q(store) + ")")?
    Ok(ApplyResult::Success)
}
