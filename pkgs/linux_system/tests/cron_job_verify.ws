use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    if fs::read("/etc/cron.d/cw-test-job")? != "# config-weave: cw-test-job\n*/5 * * * * root /bin/true\n" {
        return Err("cw-test-job not written")
    }
    if fs::read("/etc/cron.d/cw-update-job")? != "# config-weave: cw-update-job\n@daily nobody date +\\%F > /tmp/cw-date\n" {
        return Err("cw-update-job not rewritten")
    }
    if fs::exists("/etc/cron.d/cw-rm-job") { return Err("cw-rm-job not removed") }
    if fs::exists("/etc/cw-evil") || fs::exists("/etc/cron.d/cw.job") || fs::exists("/etc/cron.d/cw-newline") {
        return Err("a rejected job was written")
    }
    Ok(true)
}
