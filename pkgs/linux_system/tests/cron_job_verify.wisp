use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let job = fs::read("/etc/cron.d/cw-test-job")?
    Ok(job.contains("*/5 * * * *") && job.contains("/bin/true") && !fs::exists("/etc/cron.d/cw-rm-job"))
}
