use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(fs::read("/etc/yum.repos.d/cw-test.repo")? == "[cw-test]\nname=Config Weave Test\nbaseurl=https://example.invalid/repo\nenabled=0\n")
}
