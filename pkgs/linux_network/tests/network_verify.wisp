use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(
        fs::read("/etc/hosts")?.contains("192.0.2.10 cw-test.local cw-test")
        && fs::read("/etc/ssh/ssh_config.d/99-config-weave-test.conf")?.contains("StrictHostKeyChecking no")
        && fs::read("/etc/ssh/sshd_config.d/99-config-weave-test.conf")? == "PasswordAuthentication no\n"
    )
}

