use value
use shell
use fs
use json
use log

// Nothing here reads configuration back: the steps' own check() already
// asserts every attribute they wrote, and re-reading it would only prove the
// resource agrees with itself. What is asserted instead is the three things
// only a live request or an on-disk artefact can settle —
//
//   * that a request really is answered the way the configuration says it
//     should be: the custom 404 body (which proves the override of an
//     INHERITED httpErrors entry took effect, not merely that it was
//     written), the 301 from the directory redirect, the header that came out
//     of a web.config rather than applicationHost.config;
//   * that the paths whose authentication and protocol settings changed are
//     still served at all, and that the site root is untouched — a later
//     sibling in this VM fetches it;
//   * that failed request tracing produced a trace file, which nothing but a
//     working tracing module writing under the worker identity can do.
//
// The certificate import is deliberately NOT re-asserted: "LocalMachine\My
// holds CN=weave-pfx.local" is exactly the statement the step's own check
// makes, and asserting it here would just be running the same PowerShell
// twice. Likewise the compression, caching and dynamic-IP thresholds: none of
// them is observable over a request that is not being blocked or compressed,
// and making the test depend on a compressed response would be asserting
// curl's Accept-Encoding rather than IIS's configuration.
//
// curl.exe (System32 on Server 2019 and later) rather than the http module,
// as in the sibling verifiers: ureq turns a 4xx into an error and two of the
// assertions below are a 404 and a 301.

fn curl(args: string) -> Result[CmdOutput, string] {
    shell::run("curl.exe --silent --show-error --max-time 30 " + args, Value::Null)
}

// No --location anywhere: a followed redirect is an unobservable one.
fn status(url: string) -> Result[string, string] {
    let out = curl("--output NUL --write-out %{{http_code}} " + url)?
    if !out.success { return Err("curl " + url + " failed: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn body(url: string) -> Result[string, string] {
    let out = curl(url)?
    if !out.success { return Err("curl " + url + " failed: " + out.stderr.trim()) }
    Ok(out.stdout)
}

fn head(url: string) -> Result[string, string] {
    let out = curl("--head " + url)?
    if !out.success { return Err("curl --head " + url + " failed: " + out.stderr.trim()) }
    Ok(out.stdout)
}

fn sleep(seconds: int) -> Result[unit, string] {
    let out = shell::powershell("Start-Sleep -Seconds " + json::to_string(Value::Int(seconds)), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn str_of(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn int_of(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(i) = v.as_int() { return i } }
    0
}

// The gather blocks hand their results to this script keyed by the gather's
// name, so facts["site_facts"]["sites"] is the sites gatherer's list. Both
// lists are keyed by name, so one lookup serves both.
fn find_named(facts: Value, gather: string, list_key: string, name: string) -> Option[Value] {
    if let Some(g) = facts.get(gather) {
        if let Some(v) = g.get(list_key) {
            if let Some(items) = v.as_list() {
                for item in items {
                    if str_of(item, "name") == name { return Some(item) }
                }
            }
        }
    }
    None
}

// A binding is reported as its bindingInformation — "*:8080:" — so the port
// is matched inside it rather than compared to it.
fn has_binding(site: Value, needle: string) -> bool {
    if let Some(bs) = site.get("bindings") {
        if let Some(items) = bs.as_list() {
            for b in items {
                if str_of(b, "binding_information").contains(needle) { return true }
            }
        }
    }
    false
}

// The freb XML for one traced request, in the site's own subdirectory of the
// tracing root. Written after the response has been sent, so the caller
// retries rather than assuming it is there the instant curl returns.
fn traced(dir: string) -> Result[bool, string] {
    if !fs::exists(dir) { return Ok(false) }
    for name in fs::list_dir(dir)? {
        if name.starts_with("fr") && name.ends_with(".xml") { return Ok(true) }
    }
    Ok(false)
}

// Every assertion below reports its reason through Err rather than
// log::warn + Ok(false): a false is rendered as a bare "verify failed", and a
// suite that takes fifty minutes to run has to say WHY when it fails.
fn verify(facts: Value) -> Result[bool, string] {
    // ---------------------------------------------------------------- gathers
    //
    // The gather blocks assert iis_info's scalars themselves. These two
    // lists cannot be asserted that way — equality against a literal list
    // would pin the stock image's sites and pools as well as the group's —
    // so the facts map is picked apart here instead. Everything asserted was
    // established by iis_site_converges, which is why a gather (which runs
    // before this test's steps) can see it at all.
    let Some(site) = find_named(facts, "site_facts", "sites", "weave-site") else {
        return Err("the sites gatherer did not report weave-site")
    }
    if str_of(site, "app_pool") != "weave-pool" {
        return Err("weave-site's root application should run in weave-pool, the gatherer says '" +
            str_of(site, "app_pool") + "'")
    }
    if str_of(site, "state").to_lower() != "started" {
        return Err("weave-site should be started, the gatherer says '" + str_of(site, "state") + "'")
    }
    if str_of(site, "physical_path") != "C:\\weave-iis\\www" {
        return Err("weave-site's root should be C:\\weave-iis\\www, the gatherer says '" +
            str_of(site, "physical_path") + "'")
    }
    if !has_binding(site, ":8080:") {
        return Err("the gatherer reported no binding on port 8080 for weave-site")
    }
    let Some(pool) = find_named(facts, "pool_facts", "app_pools", "weave-pool") else {
        return Err("the app_pools gatherer did not report weave-pool")
    }
    // managed_runtime_version is the empty string for :none — the pool serves
    // static content and loads no CLR.
    if str_of(pool, "managed_runtime_version") != "" {
        return Err("weave-pool should have no managed runtime, the gatherer says '" +
            str_of(pool, "managed_runtime_version") + "'")
    }
    if str_of(pool, "managed_pipeline_mode").to_lower() != "integrated" {
        return Err("weave-pool should be in integrated mode, the gatherer says '" +
            str_of(pool, "managed_pipeline_mode") + "'")
    }
    if str_of(pool, "identity_type").to_lower() != "applicationpoolidentity" {
        return Err("weave-pool should run as ApplicationPoolIdentity, the gatherer says '" +
            str_of(pool, "identity_type") + "'")
    }

    // ---------------------------------------------------------------- requests
    //
    // The site root first, because it is the assertion the rest of the VM
    // depends on: nothing this test did may have closed it.
    let root = status("http://localhost:8080/")?
    if root != "200" {
        return Err("the site root should still be anonymous and serving, got " + root)
    }
    // The new application serves, which also says the digest and
    // certificate-mapping schemes on /authx and the protocol switch on
    // /content did not break the pipeline — a 500.19 or a 500.21 from a
    // section IIS would not accept is exactly what this catches.
    if !body("http://localhost:8080/content/")?.contains("weave-content-ok") {
        return Err("/content did not serve its index document")
    }
    let authx = status("http://localhost:8080/authx/")?
    if authx != "200" {
        return Err("/authx should still be served anonymously with Digest and IIS certificate " +
            "mapping merely OFFERED, got " + authx)
    }

    // The header written into the site's web.config rather than
    // applicationHost.config — on the wire, and then as the file only the
    // :web_config store can have created.
    if !head("http://localhost:8080/")?.contains("X-Weave-WebConfig: yes") {
        return Err("the header written through store = :web_config is not being sent")
    }
    let web_config = "C:\\weave-iis\\www\\web.config"
    if !fs::exists(web_config) {
        return Err("store = :web_config sent the header but wrote no " + web_config)
    }
    if !fs::read(web_config)?.contains("X-Weave-WebConfig") {
        return Err(web_config + " does not name the header, so it came from somewhere else")
    }

    // The directory redirect. /moved holds a real index.html, so a 200 here
    // would mean httpRedirect never engaged rather than that the document is
    // missing.
    let moved = status("http://localhost:8080/moved/")?
    if moved != "301" {
        return Err("expected 301 from the /moved directory redirect, got " + moved)
    }
    let moved_headers = head("http://localhost:8080/moved/")?
    if !moved_headers.contains("http://localhost:8080/new/index.html") {
        return Err("the redirect did not send exactDestination's verbatim target")
    }

    // The 404 override. Two separate claims: the status is still 404 (an
    // ExecuteURL custom error must not turn into a 200), and the body is our
    // document, which is the only proof that patching an entry the location
    // merely INHERITS from the server level reaches the request pipeline.
    // errorMode = Custom is what lets a request from the guest itself see it
    // at all; with the shipped DetailedLocalOnly this would be IIS's own
    // diagnostic page.
    let missing = "http://localhost:8080/content/does-not-exist.html"
    let code = status(missing)?
    if code != "404" {
        return Err("expected 404 from a missing document under /content, got " + code)
    }
    let page = body(missing)?
    if !page.contains("weave-custom-404") {
        return Err("the inherited 404 entry was not overridden — the body was not the custom " +
            "document: " + page.trim())
    }

    // Failed request tracing. The 404s above are what the rule matches
    // (*.html, status 404), so the trace file is a consequence of requests
    // already made; the extra one is only to make sure at least one landed
    // after the rule was in place. The log goes under the shipped tracing
    // root, in the site's own W3SVC<id> directory — and the id comes from the
    // sites gatherer, which is the other reason the facts are worth having.
    let trace_dir = "C:\\inetpub\\logs\\FailedReqLogFiles\\W3SVC" +
        json::to_string(Value::Int(int_of(site, "id")))
    let again = status(missing)?
    if again != "404" {
        return Err("the second request for a missing document answered " + again)
    }
    // Written asynchronously once the response has gone out, so this waits
    // rather than sampling once.
    let found = false
    let tries = 0
    while !found && tries < 6 {
        sleep(2)?
        found = traced(trace_dir)?
        tries = tries + 1
    }
    if !found {
        return Err("no failed request trace log appeared in " + trace_dir +
            " after two traced 404s")
    }
    Ok(true)
}
