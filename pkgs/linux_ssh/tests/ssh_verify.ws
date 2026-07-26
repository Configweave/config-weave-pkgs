use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let keys = fs::read("/root/.ssh/authorized_keys")?
    let known = fs::read("/root/.ssh/known_hosts")?
    let client = fs::read("/etc/ssh/ssh_config.d/50-config-weave-stricthostkeychecking.conf")?
    let daemon = fs::read("/etc/ssh/sshd_config.d/50-config-weave-passwordauthentication.conf")?
    Ok(
        keys.contains("config-weave") && !keys.contains("cw-old") &&
        known.contains("cw-test.example ssh-ed25519") &&
        client.contains("StrictHostKeyChecking no") &&
        daemon == "PasswordAuthentication no\n" &&
        !fs::exists("/etc/ssh/sshd_config.d/50-config-weave-x11forwarding.conf")
    )
}
