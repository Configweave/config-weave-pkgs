use value
use fs

fn repo(alias: string) -> Result[string, string] {
    let p = "/etc/zypp/repos.d/" + alias + ".repo"
    if !fs::is_file(p) { return Ok("") }
    fs::read(p)
}

fn has(text: string, line: string) -> bool { text.split("\n").contains(line) }

fn verify(facts: Value) -> Result[bool, string] {
    let n = repo("cw-new")?
    if !has(n, "name=CW New") || !has(n, "enabled=1") || !has(n, "autorefresh=1") || !has(n, "baseurl=dir:/srv/cw-plain") || has(n, "gpgcheck=0") {
        return Err("cw-new is not as declared:\n" + n)
    }
    let d = repo("cw-drift")?
    if !has(d, "name=CW Drift") || !has(d, "enabled=1") || !has(d, "autorefresh=1") || has(d, "gpgcheck=0") {
        return Err("cw-drift still drifted:\n" + d)
    }
    let m = repo("cw-moved")?
    if !has(m, "baseurl=dir:/srv/cw-plain") || !has(m, "enabled=0") || !has(m, "autorefresh=0") || !has(m, "gpgcheck=0") {
        return Err("cw-moved is not as declared:\n" + m)
    }
    if repo("cw-gone")? != "" { return Err("cw-gone should be removed") }
    Ok(true)
}
