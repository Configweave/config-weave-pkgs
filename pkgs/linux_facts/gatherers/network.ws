use value
use fs
use shell
use common

fn read_sys(p: string) -> string {
    if fs::exists(p) { fs::read(p).unwrap_or("").trim() } else { "" }
}

// One address record per `ip -o addr` line: [iface, family, bare address].
// Best effort — iproute2 may be absent (minimal containers), leaving lists empty.
fn addr_records() -> List[List[string]] {
    let recs = []
    for line in common::run_stdout("ip -o addr 2>/dev/null").split("\n") {
        if line.trim() == "" { continue }
        let p = common::fields(line)
        let name = p.get(1).unwrap_or("").split("@").get(0).unwrap_or("")
        let fam = p.get(2).unwrap_or("")
        let addr = p.get(3).unwrap_or("").split("/").get(0).unwrap_or("")
        if name == "" || addr == "" { continue }
        if fam == "inet" || fam == "inet6" { recs.push([name, fam, addr]) }
    }
    recs
}

fn detect_network_system() -> string {
    // netplan first: on netplan hosts networkd/NetworkManager is just the
    // renderer — netplan is the layer the operator edits.
    if !fs::glob("/etc/netplan/*.yaml").unwrap_or([]).is_empty() { return "netplan" }
    if common::run_ok("systemctl is-active --quiet NetworkManager 2>/dev/null") { return "NetworkManager" }
    if common::run_ok("systemctl is-active --quiet systemd-networkd 2>/dev/null") { return "systemd-networkd" }
    if common::run_ok("systemctl is-active --quiet wicked 2>/dev/null") { return "wicked" }
    if fs::is_file("/etc/network/interfaces") { return "ifupdown" }
    "unknown"
}

fn gather(params: Value) -> Result[Value, string] {
    let recs = addr_records()
    let ifaces = []
    for name in fs::list_dir("/sys/class/net").unwrap_or([]) {
        let v4 = []
        let v6 = []
        for r in recs {
            if r.get(0).unwrap_or("") != name { continue }
            let fam = r.get(1).unwrap_or("")
            let addr = Value::String(r.get(2).unwrap_or(""))
            if fam == "inet" { v4.push(addr) } else { v6.push(addr) }
        }
        ifaces.push(Value::Map(#{
            "name": Value::String(name),
            "mac": Value::String(read_sys("/sys/class/net/" + name + "/address")),
            "state": Value::String(read_sys("/sys/class/net/" + name + "/operstate")),
            "ipv4": Value::List(v4),
            "ipv6": Value::List(v6)
        }))
    }
    Ok(Value::Map(#{
        "interfaces": Value::List(ifaces),
        "network_system": Value::String(detect_network_system())
    }))
}
