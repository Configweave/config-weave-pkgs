use value
use fs

// Every failed expectation, so one run shows them all.
fn problems() -> Result[List[string], string] {
    let errs = []
    let d = "/etc/systemd/system/"
    // A timer, not a service: `unit_file` covers the unit types that
    // `service` does not.
    if fs::read(d + "config-weave-test.timer")? != "[Unit]\nDescription=Config Weave Test\n" { errs.push("config-weave-test.timer content") }
    if fs::read(d + "cw-drift.timer")? != "[Unit]\nDescription=Config Weave drift\n" { errs.push("cw-drift.timer still drifted") }
    if fs::read(d + "cw-new.service.d/override.conf")? != "[Service]\nEnvironment=CW=1\n" { errs.push("drop-in content") }
    if fs::exists(d + "cw-gone.timer") { errs.push("cw-gone.timer still present") }
    if fs::exists(d + "cw-old.service.d") { errs.push("emptied drop-in directory still present") }
    if fs::exists("/etc/cw-escape.conf") || fs::exists("/tmp/cw-escape.service") { errs.push("a traversing name escaped /etc/systemd/system") }
    Ok(errs)
}

fn verify(facts: Value) -> Result[bool, string] {
    let errs = problems()?
    if !errs.is_empty() { return Err(errs.join("; ")) }
    Ok(true)
}
