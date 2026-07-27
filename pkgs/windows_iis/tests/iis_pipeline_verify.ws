use value
use shell
use fs
use log

// Three kinds of assertion, and nothing else.
//
// First, on disk: the DLLs the steps NAME. The handler mapping names
// CgiModule, the asp section only exists because asp.dll was installed, and
// the global_module registration points at static.dll — if any of those three
// files is not where the step said it was, the step converged against a
// fiction. `config-weave test` already proves the role services installed,
// through the feature steps' own check(), so this is about the paths, not the
// features.
//
// Second, over the wire: the site root, /app and /pipeline must all still
// serve. That is not a formality — this test registers a native global
// module (loaded by every worker process), an ISAPI filter and a managed
// module, and installs five role services that each rewrite
// applicationHost.config's module and handler lists. A 200 from the root is
// the statement that none of it broke the server the three earlier tests in
// this VM built.
//
// Third, the one behaviour a live request can prove about the pipeline
// itself: a request for the extension the CGI handler claims is refused with
// a 403, because the handler asks for Execute and /pipeline's access policy
// grants Read alone. A 404 there would mean the handler never claimed the
// path; a 200 would mean the static file handler answered instead.
//
// Everything else the steps configured is deliberately NOT re-read here. The
// FastCGI application and its environment variable, the ISAPI filter, the
// ISAPI/CGI restriction entry, the global module, the warm-up page and the
// asp / cgi / serverRuntime attributes cannot be observed through a request
// without an interpreter, an ISAPI DLL or a worker restart to warm up — and
// reading them back out of applicationHost.config would only repeat what
// each step's own check() asserted on runs 2 and 3, which is the stronger
// statement.
//
// curl.exe (System32 on Server 2019 and later) rather than the http module:
// ureq treats a 4xx as an error, and the 403 is the point.

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

fn serves(url: string, marker: string) -> Result[bool, string] {
    let code = status(url)?
    if code != "200" {
        log::warn("expected 200 from " + url + ", got " + code)
        return Ok(false)
    }
    if !body(url)?.contains(marker) {
        log::warn(url + " answered 200 but not with '" + marker + "'")
        return Ok(false)
    }
    Ok(true)
}

fn verify(facts: Value) -> Result[bool, string] {
    // The CGI module DLL the handler mapping names.
    if !fs::exists("C:\\Windows\\System32\\inetsrv\\cgi.dll") {
        log::warn("cgi.dll is not in inetsrv, so the handler names a module that cannot load")
        return Ok(false)
    }
    // The classic ASP extension, whose section the asp step configured.
    if !fs::exists("C:\\Windows\\System32\\inetsrv\\asp.dll") {
        log::warn("asp.dll is not in inetsrv, so the asp section has nothing behind it")
        return Ok(false)
    }
    // The image the global module registration points at.
    if !fs::exists("C:\\Windows\\System32\\inetsrv\\static.dll") {
        log::warn("static.dll is not in inetsrv, so the global module registration is a dangling path")
        return Ok(false)
    }

    // The site the three earlier tests built still serves.
    if !serves("http://localhost:8080/", "weave-iis-ok")? { return Ok(false) }
    // ...and so does the sibling application, which none of this touched:
    // every location-scoped step here wrote under /pipeline.
    if !serves("http://localhost:8080/app/", "weave-iis-ok")? { return Ok(false) }
    // The new application serves its index document even though its handler
    // access policy was narrowed to Read: static content asks for Read and
    // nothing more.
    if !serves("http://localhost:8080/pipeline/", "weave-pipeline-ok")? { return Ok(false) }

    // The refusal. The file is deliberately absent, which makes the assertion
    // independent of how IIS breaks a tie between the *.weave-cgi mapping and
    // the inherited StaticFile mapping at "*": with nothing on disk the
    // static mapping cannot claim the request at all, so the only handler
    // left is the one this test added, and its requireAccess = Execute is
    // refused before any process is started.
    let url = "http://localhost:8080/pipeline/absent.weave-cgi"
    let code = status(url)?
    if code != "403" {
        log::warn("expected 403 from the CGI handler path, got " + code)
        // IIS names the substatus in the error page, which is what tells a
        // 404.0 (handler never matched) from a 500.21 (bad module) apart.
        log::warn(body(url)?.trim())
        return Ok(false)
    }
    Ok(true)
}
