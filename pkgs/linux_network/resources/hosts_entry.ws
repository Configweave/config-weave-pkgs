use value
use common
use fs

// /etc/hosts is rewritten in place rather than through a temp file and
// rename: container runtimes bind-mount it, and a rename over a bind mount
// fails.
fn hosts_path() -> string { "/etc/hosts" }

fn names(params: Value) -> Result[List[string], string] {
    let out = []
    if let Some(v) = params.get("names") {
        if let Some(l) = v.as_list() {
            for item in l {
                if let Some(s) = item.as_string() {
                    common::token("names", s)?
                    if s.contains("#") { return Err("host name '" + s + "' must not contain '#'") }
                    out.push(s)
                }
            }
        }
    }
    Ok(out)
}

fn valid_ip(params: Value) -> Result[string, string] {
    let ip = common::param_str(params, "ip", "")
    common::token("ip", ip)?
    if ip.contains("#") { return Err("'ip' must not contain '#'") }
    Ok(ip)
}

// The fields of a hosts line: whitespace-separated tokens, comment dropped.
fn fields(line: string) -> List[string] {
    let body = if let Some(i) = line.find("#") { line.slice(0, i) } else { line }
    let out = []
    for t in body.replace("\t", " ").split(" ") { if t != "" { out.push(t) } }
    out
}

// The file with every line for `ip` removed, and, when `want` is not empty,
// `want` in place of the first of them (or appended when there was none).
// Comments, blank lines and other addresses' lines are kept as they are.
fn rewrite(text: string, ip: string, want: string) -> string {
    let lines = text.split("\n")
    if text.ends_with("\n") { let dropped = lines.remove(lines.len() - 1) }
    let out = []
    let placed = false
    for line in lines {
        let f = fields(line)
        if f.len() > 0 && f.get(0).unwrap_or("") == ip {
            if want != "" && !placed {
                out.push(want)
                placed = true
            }
            continue
        }
        out.push(line)
    }
    if want != "" && !placed { out.push(want) }
    if out.len() == 0 { "" } else { out.join("\n") + "\n" }
}

// Converged when exactly one line maps `ip`, with exactly `names` in order
// (whitespace between them and a trailing comment do not matter).
fn converged(text: string, ip: string, want_names: List[string], present: bool) -> bool {
    let found = 0
    let matches = false
    for line in text.split("\n") {
        let f = fields(line)
        if f.len() == 0 || f.get(0).unwrap_or("") != ip { continue }
        found = found + 1
        let got = []
        for i in 1..f.len() { got.push(f.get(i).unwrap_or("")) }
        matches = got.join(" ") == want_names.join(" ")
    }
    if !present { return found == 0 }
    found == 1 && matches
}

fn read_hosts() -> string {
    // An unreadable (non-UTF-8) file reads as drift; apply refuses to
    // rewrite it rather than lose the bytes it cannot decode.
    if !fs::is_file(hosts_path()) { return "" }
    fs::read(hosts_path()).unwrap_or("")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let ip = valid_ip(params)?
    let present = common::want_present(params)?
    let want = names(params)?
    if present && want.is_empty() { return Err("missing 'names' parameter (a non-empty list of host names)") }
    if converged(read_hosts(), ip, want, present) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let ip = valid_ip(params)?
    let present = common::want_present(params)?
    let want = names(params)?
    if present && want.is_empty() { return Err("missing 'names' parameter (a non-empty list of host names)") }
    if fs::is_file(hosts_path()) && fs::read(hosts_path()).is_err() {
        return Err(hosts_path() + " is not valid UTF-8; refusing to rewrite it")
    }
    let line = if present { ip + " " + want.join(" ") } else { "" }
    fs::write(hosts_path(), rewrite(read_hosts(), ip, line))?
    Ok(ApplyResult::Success)
}
