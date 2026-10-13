use value
use json
use shell

fn sh(cmd: string) -> Result[string, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd + " failed: " + out.stderr.trim()) }
    Ok(out.stdout)
}

fn field(m: Value, k: string) -> string {
    if let Some(v) = m.get(k) {
        if let Some(s) = v.as_string() { return s }
        if let Some(i) = v.as_int() { return str(i) }
    }
    ""
}

// "type hook prio policy" of a chain, from nft -j.
fn chain_shape(spec: string) -> Result[string, string] {
    let doc = json::parse(sh("nft -j list chain " + spec)?)?
    if let Some(v) = doc.get("nftables") {
        if let Some(items) = v.as_list() {
            for item in items {
                if let Some(c) = item.get("chain") {
                    return Ok(field(c, "type") + " " + field(c, "hook") + " " + field(c, "prio") + " " + field(c, "policy"))
                }
            }
        }
    }
    Err("no chain in nft -j list chain " + spec)
}

fn count(text: string, needle: string) -> int {
    let n = 0
    for l in text.split("\n") { if l.contains(needle) { n = n + 1 } }
    n
}

fn expect(what: string, got: string, want: string) -> Result[unit, string] {
    if got != want { return Err(what + ": expected '" + want + "', got '" + got + "'") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    expect("cwtest input", chain_shape("inet cwtest input")?, "filter input 0 accept")?
    expect("cwtest jumps", chain_shape("inet cwtest jumps")?, "   ")?
    expect("cwseed seedfwd", chain_shape("inet cwseed seedfwd")?, "filter forward 0 accept")?
    expect("cwseed reshape", chain_shape("inet cwseed reshape")?, "filter prerouting -5 accept")?

    let input = sh("nft list chain inet cwtest input")?
    if count(input, "tcp dport 8080 accept") != 1 { return Err("expected one 8080 rule in: " + input) }
    if count(input, "tcp dport 8081 counter") != 1 { return Err("expected one 8081 rule in: " + input) }
    if count(input, "dport 22 ") != 0 { return Err("the refused ssh rule was left behind: " + input) }

    let fwd = sh("nft list chain inet cwseed seedfwd")?
    if count(fwd, "tcp dport 2222 counter") != 1 { return Err("the seeded 2222 rule was lost or duplicated: " + fwd) }
    if count(fwd, "udp dport 5353") != 0 { return Err("the 5353 rules were not deleted: " + fwd) }

    let all = sh("nft list tables")?
    if all.contains("cwgone") { return Err("table ip cwgone was not deleted") }
    if all.contains("cwpwned") { return Err("the injected nft command ran") }
    if shell::bash("nft list chain inet cwseed doomed", Value::Null)?.success { return Err("chain cwseed doomed was not deleted") }
    if shell::bash("nft list chain inet cwtest nopolicy", Value::Null)?.success { return Err("chain nopolicy was created") }
    Ok(true)
}
