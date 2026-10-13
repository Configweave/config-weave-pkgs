use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let d = "/etc/ssh/sshd_config.d/"
    if fs::exists(d + "50-config-weave-x11forwarding.conf") || fs::exists(d + "50-config-weave-maxauthtries.conf") {
        return Err("an old-named drop-in was left behind")
    }
    if fs::read(d + "10-config-weave-x11forwarding.conf")? != "X11Forwarding no\n" { return Err("X11Forwarding not migrated") }
    if fs::read(d + "10-config-weave-loglevel.conf")? != "LogLevel VERBOSE\n" { return Err("the rejected LogLevel was not rolled back") }
    if fs::exists(d + "10-config-weave-maxsessions.conf") { return Err("the rejected MaxSessions drop-in was left behind") }
    if fs::exists(d + "10-config-weave-clientaliveinterval.conf") { return Err("the shadowed drop-in was left behind") }
    if fs::exists(d + "10-config-weave-match.conf") || fs::exists(d + "10-config-weave-permitrootlogin.conf") { return Err("a rejected key was written") }

    let t = shell::bash("/usr/sbin/sshd -T", Value::Null)?
    if !t.success { return Err("sshd -T failed: " + t.stderr) }
    let lines = t.stdout.split("\n")
    for want in ["passwordauthentication no", "x11forwarding no", "logingracetime 120", "banner /etc/cw-banner", "loglevel VERBOSE", "clientaliveinterval 30", "maxsessions 10"] {
        if !lines.contains(want) { return Err("sshd -T lacks '" + want + "'") }
    }

    // only a reloaded sshd shows a banner it did not start with
    let ssh = shell::bash("ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost true 2>&1", Value::Null)?
    if !ssh.stdout.contains("cw-banner-text") { return Err("running sshd shows no banner: " + ssh.stdout) }
    Ok(true)
}
