use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(
        fs::read("/etc/sysctl.d/99-config-weave-test.conf")? == "fs.file-max = 100000\n"
        && fs::read("/etc/cron.d/config-weave-test")? == "SHELL=/bin/sh\n"
        && fs::read("/etc/logrotate.d/config-weave-test")?.contains("missingok")
    )
}

