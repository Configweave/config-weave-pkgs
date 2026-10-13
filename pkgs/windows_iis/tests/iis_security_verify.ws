use value
use shell

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
        return Err("expected 401 from /secure, got " + secure)
    }
    // The challenge names both schemes that were enabled.
    let headers = curl("--head http://localhost:8080/secure/")?.stdout
    if !headers.contains("WWW-Authenticate") {
        return Err("the 401 carried no WWW-Authenticate challenge")
    }
    if !headers.to_lower().contains("basic realm=\"weave\"") {
        return Err("the Basic challenge is missing or carries the wrong realm")
    }
    // request_filtering set removeServerHeader on /secure only.
    if headers.contains("Server: Microsoft-IIS") {
        return Err("the Server header was not stripped from /secure")
    }
    // Windows authentication offers both providers it was given.
    if !headers.contains("WWW-Authenticate: Negotiate") || !headers.contains("WWW-Authenticate: NTLM") {
        return Err("the 401 does not offer both Negotiate and NTLM")
    }
    // Request filtering runs before authentication, so a denied extension
    // or a hidden segment is a 404 even without credentials, where any other
    // missing file under /secure is the 401 of the authentication challenge.
    // With the rules gone both of these would be 401.
    let missing = status("http://localhost:8080/secure/missing.html")?
    if missing != "401" {
        return Err("expected 401 for a missing file under /secure, got " + missing)
    }
    let denied = status("http://localhost:8080/secure/file.weave")?
    if denied != "404" {
        return Err("expected 404 for the denied .weave extension, got " + denied)
    }
    let hidden = status("http://localhost:8080/secure/weave-private/index.html")?
    if hidden != "404" {
        return Err("expected 404 under the hidden weave-private segment, got " + hidden)
    }
    let root = status("http://localhost:8080/")?
    if root != "200" {
        return Err("the site root should still be anonymous, got " + root)
    }
    Ok(true)
}
