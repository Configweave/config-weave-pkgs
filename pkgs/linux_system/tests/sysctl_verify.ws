use value
use fs
use shell

fn sysctl(key: string) -> Result[string, string] {
    let out = shell::bash("sysctl -n " + key, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim().replace("\t", " "))
}

fn verify(facts: Value) -> Result[bool, string] {
    if sysctl("net.ipv4.ip_local_port_range")? != "32000 61000" { return Err("port range not set") }
    if fs::read("/etc/sysctl.d/99-config-weave-net-ipv4-ip_local_port_range.conf")? != "net.ipv4.ip_local_port_range = 32000 61000\n" {
        return Err("port range drop-in wrong")
    }
    if sysctl("net.ipv4.ip_forward")? != "1" { return Err("ip_forward not set") }
    if fs::read("/etc/sysctl.d/99-config-weave-net-ipv4-ip_forward.conf")? != "net/ipv4/ip_forward = 1\n" {
        return Err("ip_forward drop-in wrong")
    }
    if fs::exists("/etc/sysctl.d/99-config-weave-net-ipv4-tcp_syncookies.conf") { return Err("syncookies drop-in not removed") }
    Ok(true)
}
