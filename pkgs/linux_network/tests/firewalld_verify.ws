use value
use shell

// Whether firewalld has a rule, in the running (cfg "") or saved
// (" --permanent") configuration.
fn has(cfg: string, query: string) -> Result[bool, string] {
    let out = shell::bash("firewall-cmd" + cfg + " " + query, Value::Null)?
    if out.code > 1 { return Err("firewall-cmd" + cfg + " " + query + " failed: " + out.stderr.trim()) }
    Ok(out.code == 0)
}

fn expect(query: string, running: bool, saved: bool) -> Result[unit, string] {
    let r = has("", query)?
    let s = has(" --permanent", query)?
    if r != running || s != saved {
        return Err(query + ": running " + str(r) + " saved " + str(s) + ", expected running " + str(running) + " saved " + str(saved))
    }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    expect("--query-port=8443/tcp", true, true)?
    expect("--query-service=https", true, true)?
    expect("--query-service=http", true, true)?
    expect("--query-port=9443/tcp", true, false)?
    expect("--zone=internal --query-source=192.0.2.0/24", true, true)?
    expect("--zone=public --query-rich-rule='rule family=ipv4 source address=203.0.113.0/24 port port=5000 protocol=tcp accept'", true, true)?
    expect("--query-port=7070/tcp", false, false)?
    expect("--query-rich-rule='rule family=ipv4 source address=198.51.100.0/24 reject'", false, false)?
    expect("--query-port=1234/tcp", false, false)?
    Ok(true)
}
