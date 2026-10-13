use value
use common

// dnf4 and yum print one lock per line as a NEVRA pattern: dnf4 as
// name-epoch:version-release.arch ("hello-0:2.10-14.fc38.*"), yum as
// epoch:name-version-release.arch ("0:hello-2.10-1.el7.*"). A leading '!'
// marks an exclude, which is not a hold. Returns "" for anything else,
// such as dnf's "Last metadata expiration check" line.
fn nevra_name(line: string, bin: string) -> string {
    let l = line.trim()
    if l == "" || l.starts_with("!") || l.starts_with("#") || l.contains(" ") { return "" }
    if bin == "yum" {
        // drop the epoch, then the version and release
        let rest = if let Some(i) = l.find(":") { l.slice(i + 1, l.len()) } else { l }
        let parts = rest.split("-")
        if parts.len() < 3 { return "" }
        return parts.slice(0, parts.len() - 2).join("-")
    }
    // dnf4: the name is everything before the '-' that precedes the epoch
    if let Some(i) = l.find(":") {
        let head = l.slice(0, i)
        let parts = head.split("-")
        if parts.len() < 2 { return "" }
        return parts.slice(0, parts.len() - 1).join("-")
    }
    ""
}

fn is_held(name: string, bin: string) -> Result[bool, string] {
    let out = common::output(bin + " versionlock list (is the versionlock plugin installed? python3-dnf-plugin-versionlock, dnf5-plugins or yum-plugin-versionlock)", bin + " versionlock list")?
    for l in out.stdout.split("\n") {
        // dnf5 prints a block per lock, headed "Package name: <name>"
        if bin == "dnf5" {
            if l.trim() == "Package name: " + name { return Ok(true) }
        } else if nevra_name(l, bin) == name {
            return Ok(true)
        }
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    let held = is_held(name, common::lock_bin()?)?
    if held == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    common::operand("name", name)?
    let bin = common::lock_bin()?
    let verb = if common::want_present(params)? { "add" } else { "delete" }
    common::run(bin + " versionlock " + verb + " " + name, bin + " versionlock " + verb + " " + common::q(name))?
    Ok(ApplyResult::Success)
}
