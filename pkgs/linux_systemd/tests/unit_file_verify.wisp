use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(fs::read("/etc/systemd/system/config-weave-test.service")? == "[Unit]\nDescription=Config Weave Test\n")
}

