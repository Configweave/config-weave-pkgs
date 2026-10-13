use value
use shell
use fs
use log

// The rules are proved by making requests that only succeed if URL Rewrite is
// loaded and evaluating them — writing the XML is what the steps' own check()
// already asserts.

fn curl(args: string) -> Result[CmdOutput, string] {
    shell::run("curl.exe --silent --show-error --insecure --max-time 30 " + args, Value::Null)
}

fn body(url: string) -> Result[string, string] {
    let out = curl(url)?
    if !out.success { return Err("curl " + url + " failed: " + out.stderr.trim()) }
    Ok(out.stdout)
}

fn status(url: string) -> Result[string, string] {
    // No --location: the redirect rule is only observable if curl does not
    // follow it.
    let out = curl("--output NUL --write-out %{{http_code}} " + url)?
    if !out.success { return Err("curl " + url + " failed: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    if !fs::exists("C:\\Windows\\System32\\inetsrv\\rewrite.dll") {
        log::warn("the URL Rewrite module was not installed")
        return Ok(false)
    }
    // The inbound rule rewrites /old/<x> to /new/<x> without telling the
    // client, so the status is 200 and the body is the /new document.
    let rewritten = curl("http://localhost:8080/old/index.html")?
    if !rewritten.stdout.contains("weave-rewritten") {
        log::warn("/old/index.html was not rewritten to /new/index.html")
        return Ok(false)
    }
    let code = status("http://localhost:8080/old/index.html")?
    if code != "200" {
        log::warn("expected 200 from the rewritten URL, got " + code)
        return Ok(false)
    }
    // The redirect rule answers 301 and points at the new location.
    let redirect = status("http://localhost:8080/gone/index.html")?
    if redirect != "301" {
        log::warn("expected 301 from the redirect rule, got " + redirect)
        return Ok(false)
    }
    let headers = curl("--head http://localhost:8080/gone/index.html")?.stdout
    if !headers.contains("/new/index.html") {
        log::warn("the redirect did not point at /new/index.html")
        return Ok(false)
    }
    // The map rule looks "page" up in weave-map and rewrites to its value.
    if !body("http://localhost:8080/mapped/page")?.contains("weave-rewritten") {
        log::warn("/mapped/page was not rewritten through weave-map to /new/index.html")
        return Ok(false)
    }
    // The conditional rule only fires with {HTTPS} ON: over HTTP there is
    // nothing at /secure-only/, over HTTPS it is /new/.
    let plain = status("http://localhost:8080/secure-only/index.html")?
    if plain != "404" {
        log::warn("the {{HTTPS}} condition should keep the rule off plain HTTP, got " + plain)
        return Ok(false)
    }
    if !body("https://localhost:8443/secure-only/index.html")?.contains("weave-rewritten") {
        log::warn("the conditional rule did not rewrite over HTTPS")
        return Ok(false)
    }
    // The outbound rule rewrites the link in an HTML response; its
    // pre-condition keeps it off the same bytes served as text/plain.
    let html = body("http://localhost:8080/links.html")?
    if !html.contains("http://new.example.com/page") {
        log::warn("the outbound rule did not rewrite the link in links.html: " + html)
        return Ok(false)
    }
    let text = body("http://localhost:8080/links.txt")?
    if !text.contains("http://old.example.com/page") {
        log::warn("the pre-condition should have kept the outbound rule off links.txt: " + text)
        return Ok(false)
    }
    Ok(true)
}
