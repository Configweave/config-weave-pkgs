use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    // A timer, not a service: `unit_file` covers the unit types that
    // `service` does not.
    Ok(fs::read("/etc/systemd/system/config-weave-test.timer")? == "[Unit]\nDescription=Config Weave Test\n")
}

