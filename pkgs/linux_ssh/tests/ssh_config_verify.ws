use value
use fs
use shell

fn effective(host: string) -> Result[List[string], string] {
    let out = shell::bash("ssh -G " + host, Value::Null)?
    if !out.success { return Err("ssh -G " + host + " failed: " + out.stderr) }
    Ok(out.stdout.split("\n"))
}

fn verify(facts: Value) -> Result[bool, string] {
    let d = "/etc/ssh/ssh_config.d/"
    if fs::exists(d + "50-config-weave-stricthostkeychecking.conf") { return Err("the old-named drop-in was left behind") }
    if !fs::exists(d + "50-config-weave-compression.conf") { return Err("another host's old-named drop-in was removed") }
    if fs::exists(d + "10-config-weave-forwardagent.conf") { return Err("ForwardAgent drop-in not removed") }
    if fs::read(d + "10-config-weave-stricthostkeychecking.conf")? != "Host *\n    StrictHostKeyChecking no\n" { return Err("all-hosts drop-in wrong") }
    let specific = fs::glob(d + "10-config-weave-stricthostkeychecking-*.conf")?
    if specific.len() != 1 { return Err("expected one host-specific drop-in, found " + str(specific.len())) }
    if fs::read(specific.get(0).unwrap_or(""))? != "Host *.cw.example\n    StrictHostKeyChecking accept-new\n" { return Err("host drop-in wrong") }
    if fs::glob("/tmp/x*")?.len() > 0 { return Err("a path key escaped the drop-in directory") }

    let one = effective("a.cw.example")?
    if !one.contains("stricthostkeychecking accept-new") { return Err("a.cw.example: " + one.join(" | ")) }
    let all = effective("plain.example")?
    if !all.contains("stricthostkeychecking false") { return Err("plain.example strict: " + all.join(" | ")) }
    if !all.contains("compression yes") || !all.contains("forwardagent no") { return Err("plain.example: " + all.join(" | ")) }
    Ok(true)
}
