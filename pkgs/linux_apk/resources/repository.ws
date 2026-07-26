use value
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn repos_file() -> string { "/etc/apk/repositories" }

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") { if l.trim() == line { return true } }
    false
}

fn without_line(text: string, line: string) -> string {
    let lines = text.split("\n")
    let out = ""
    for i in 0..lines.len() {
        let l = lines[i]
        if i == lines.len() - 1 && l == "" { continue }
        if l.trim() == line { continue }
        out = out + l + "\n"
    }
    out
}

fn check(params: Value) -> Result[CheckResult, string] {
    let url = param_str(params, "url", "")
    if url == "" { return Err("missing 'url' parameter") }
    let text = if fs::is_file(repos_file()) { fs::read(repos_file())? } else { "" }
    if has_line(text, url) == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let url = param_str(params, "url", "")
    if url == "" { return Err("missing 'url' parameter") }
    let text = if fs::is_file(repos_file()) { fs::read(repos_file())? } else { "" }
    if want_present(params)? {
        if !has_line(text, url) {
            let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
            fs::write(repos_file(), text + sep + url + "\n")?
        }
        return Ok(ApplyResult::Success)
    }
    if has_line(text, url) { fs::write(repos_file(), without_line(text, url))? }
    Ok(ApplyResult::Success)
}
