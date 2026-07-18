use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let user_ok = shell::bash("id -u cwtest >/dev/null 2>&1", Value::Null)?.success
    let key_ok = fs::read("/home/cwtest/.ssh/authorized_keys")?.contains("config-weave")
    let sudo_ok = fs::is_file("/etc/sudoers.d/cwtest") && fs::read("/etc/sudoers.d/cwtest")?.contains("NOPASSWD: ALL")
    let old_user_gone = !shell::bash("id -u cwold >/dev/null 2>&1", Value::Null)?.success
    let old_group_gone = !shell::bash("getent group cwoldgrp >/dev/null", Value::Null)?.success
    let old_home_gone = !fs::exists("/home/cwold")
    let old_sudo_gone = !fs::exists("/etc/sudoers.d/cwold")
    Ok(user_ok && key_ok && sudo_ok && old_user_gone && old_group_gone && old_home_gone && old_sudo_gone)
}
