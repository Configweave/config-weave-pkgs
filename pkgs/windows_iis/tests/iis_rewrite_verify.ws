use value
use shell
use fs
use log

// The rules are proved by making requests that only succeed if URL Rewrite is
// loaded and evaluating them — writing the XML is what the steps' own check()
// already asserts.

fn curl(args: string) -> Result[CmdOutput, string] {
    shell::run("curl.exe --silent --show-error --max-time 30 " + args, Value::Null)
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
    Ok(true)
}
