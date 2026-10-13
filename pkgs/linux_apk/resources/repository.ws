use value
use fs
use common

fn repos_file() -> string { "/etc/apk/repositories" }

// The repository line, trimmed the way lines in the file are compared.
fn line(params: Value) -> Result[string, string] {
    let raw = common::param_str(params, "url", "")
    common::one_line("url", raw)?
    let url = raw.trim()
    if url == "" { return Err("missing 'url' parameter") }
    if url.starts_with("#") { return Err("'url' must not start with '#': apk reads that line as a comment") }
    Ok(url)
}

// Commented lines are not matches: apk ignores them.
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

fn read_repos() -> Result[string, string] {
    if fs::is_file(repos_file()) { fs::read(repos_file()) } else { Ok("") }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let url = line(params)?
    if has_line(read_repos()?, url) == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

// Writing the file bumps its mtime past cache_updated's stamp, so the next
// cache_updated refreshes the index whatever its max_age.
fn apply(params: Value) -> Result[ApplyResult, string] {
    let url = line(params)?
    let text = read_repos()?
    if common::want_present(params)? {
        if !has_line(text, url) {
            let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
            fs::write(repos_file(), text + sep + url + "\n")?
        }
        return Ok(ApplyResult::Success)
    }
    if has_line(text, url) { fs::write(repos_file(), without_line(text, url))? }
    Ok(ApplyResult::Success)
}
