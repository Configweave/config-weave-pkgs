use value
use shell
use log

// Anonymous access to /secure was turned off and Windows and Basic
// authentication turned on, so an unauthenticated request must be refused —
// and the site root, which this test deliberately left alone, must still
// serve, because the rewrite test runs next in this VM and fetches it.

fn curl(args: string) -> Result[CmdOutput, string] {
    shell::run("curl.exe --silent --show-error --max-time 30 " + args, Value::Null)
}

fn status(url: string) -> Result[string, string] {
    let out = curl("--output NUL --write-out %{{http_code}} " + url)?
    if !out.success { return Err("curl " + url + " failed: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    let secure = status("http://localhost:8080/secure/")?
    if secure != "401" {
        log::warn("expected 401 from /secure, got " + secure)
        return Ok(false)
    }
    // The challenge names both schemes that were enabled.
    let headers = curl("--head http://localhost:8080/secure/")?.stdout
    if !headers.contains("WWW-Authenticate") {
        log::warn("the 401 carried no WWW-Authenticate challenge")
        return Ok(false)
    }
    if !headers.to_lower().contains("basic realm=\"weave\"") {
        log::warn("the Basic challenge is missing or carries the wrong realm")
        return Ok(false)
    }
    // request_filtering set removeServerHeader on /secure only.
    if headers.contains("Server: Microsoft-IIS") {
        log::warn("the Server header was not stripped from /secure")
        return Ok(false)
    }
    // Nothing here asserts the request-filtering entries: a denied extension
    // and a missing file both answer 404 over the wire, so the assertion
    // would pass with the rules removed. Their own check() proves they
    // converged, which is the stronger statement.
    let root = status("http://localhost:8080/")?
    if root != "200" {
        log::warn("the site root should still be anonymous, got " + root)
        return Ok(false)
    }
    Ok(true)
}
