use value
use fs

// The hosts lines for one address, as whitespace-joined fields.
fn lines_for(text: string, ip: string) -> List[string] {
    let out = []
    for line in text.split("\n") {
        let body = if let Some(i) = line.find("#") { line.slice(0, i) } else { line }
        let f = []
        for t in body.replace("\t", " ").split(" ") { if t != "" { f.push(t) } }
        if f.len() > 0 && f.get(0).unwrap_or("") == ip { out.push(f.join(" ")) }
    }
    out
}

fn expect_lines(text: string, ip: string, want: List[string]) -> Result[unit, string] {
    let got = lines_for(text, ip)
    if got.join("|") != want.join("|") { return Err(ip + ": expected [" + want.join("|") + "], got [" + got.join("|") + "]") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    let hosts = fs::read("/etc/hosts")?
    expect_lines(hosts, "192.0.2.10", ["192.0.2.10 cw-test.local cw-test"])?
    expect_lines(hosts, "192.0.2.20", ["192.0.2.20 cw-new.local cw-new"])?
    expect_lines(hosts, "192.0.2.30", ["192.0.2.30 cw-spaced cw-sp"])?
    expect_lines(hosts, "192.0.2.40", [])?
    expect_lines(hosts, "192.0.2.50", [])?
    if !hosts.contains("# keep me\n") { return Err("a comment line was lost") }
    if !hosts.contains("localhost") { return Err("the original entries were lost") }
    Ok(true)
}
