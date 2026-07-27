use value
use shell
use log

// The site is checked by fetching from it, not by reading configuration back:
// the steps already assert the configuration through their own check(), and a
// live request is the only thing that proves the pool starts, the binding
// listens and the handler chain serves.
//
// curl.exe ships in System32 on Server 2019 and later. It is used rather than
// the http module because ureq treats a 4xx as an error and the sibling
// security test needs to observe a 401 — keeping both verifiers on the same
// tool keeps them comparable.

fn curl(args: string) -> Result[CmdOutput, string] {
    shell::run("curl.exe --silent --show-error --max-time 30 " + args, Value::Null)
}

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

fn verify(facts: Value) -> Result[bool, string] {
    let code = status("http://localhost:8080/")?
    if code != "200" {
        log::warn("expected 200 from the site root, got " + code)
        return Ok(false)
    }
    // default_document sent index.html for a directory request.
    if !body("http://localhost:8080/")?.contains("weave-iis-ok") {
        log::warn("the site root did not serve the index document")
        return Ok(false)
    }
    // The virtual directory maps /static onto its own physical path.
    if !body("http://localhost:8080/static/")?.contains("weave-static-ok") {
        log::warn("/static did not serve the virtual directory's content")
        return Ok(false)
    }
    // Both custom response headers — the typed one and the one added through
    // the generic collection escape hatch.
    let headers = curl("--head http://localhost:8080/")?.stdout
    if !headers.contains("X-Weave: iis") {
        log::warn("the custom response header is missing")
        return Ok(false)
    }
    if !headers.contains("X-Weave-Generic: yes") {
        log::warn("the header added by config_collection_element is missing")
        return Ok(false)
    }
    // The TLS binding really terminates, with the self-signed certificate the
    // certificate step created. --insecure because it is self-signed.
    let tls = curl("--insecure --output NUL --write-out %{{http_code}} https://localhost:8443/")?
    if !tls.success || tls.stdout.trim() != "200" {
        log::warn("expected 200 over TLS on 8443, got '" + tls.stdout.trim() + "' " + tls.stderr.trim())
        return Ok(false)
    }
    Ok(true)
}
