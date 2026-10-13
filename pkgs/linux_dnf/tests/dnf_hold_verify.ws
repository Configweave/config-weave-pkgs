use value
use fs
use shell

fn locked(pattern: string) -> Result[bool, string] {
    let out = shell::bash("dnf versionlock list 2>/dev/null | grep -Eq " + pattern, Value::Null)?
    Ok(out.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    if fs::exists("/usr/bin/dnf5") {
        if !locked("'^Package name: dnf5$'")? { return Err("dnf5 should be locked") }
        if !locked("'^Package name: dnf5-plugins$'")? { return Err("dnf5-plugins should still be locked") }
        if locked("'^Package name: tzdata$'")? { return Err("tzdata should be unlocked") }
    } else {
        if !locked("'^dnf-[0-9]+:'")? { return Err("dnf should be locked") }
        if !locked("'^dnf-data-[0-9]+:'")? { return Err("dnf-data should still be locked") }
        if locked("'^tzdata-[0-9]+:'")? { return Err("tzdata should be unlocked") }
    }
    Ok(true)
}
