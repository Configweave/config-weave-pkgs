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

// Under systemd, ask it; elsewhere (OpenRC, runit, containers) look for
// the daemon's process. The bare token is returned without a leading
// colon; the engine promotes it to a WCL symbol.
fn active(unit: string, comm: string) -> bool {
    common::run_ok("systemctl is-active --quiet " + unit + " 2>/dev/null") || common::process_running(comm)
}

fn detect_network_system() -> string {
    // netplan first: on netplan hosts networkd/NetworkManager is just the
    // renderer — netplan is the layer the operator edits.
    if !fs::glob("/etc/netplan/*.yaml").unwrap_or([]).is_empty() { return "netplan" }
    if active("NetworkManager", "NetworkManager") { return "network_manager" }
    if active("systemd-networkd", "systemd-network") { return "systemd_networkd" }
    if active("wicked", "wickedd") { return "wicked" }
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
