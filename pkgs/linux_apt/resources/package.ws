use value
use shell
use common

fn validate(params: Value) -> Result[unit, string] {
    common::operand("name", common::param_str(params, "name", ""))?
    let version = common::param_str(params, "version", "")
    if version != "" { common::operand("version", version)? }
    Ok(())
}

// One "<status> <version>" line per installed architecture; none when dpkg
// has never heard of the package. The version survives in the
// removed-but-config ("rc") state, so it is only meaningful next to the
// status.
fn states(name: string) -> Result[List[List[string]], string] {
    let out = shell::bash("dpkg-query -W -f='${{db:Status-Status}} ${{Version}}\\n' " + common::q(name) + " 2>/dev/null", Value::Null)?
    let found = []
    if !out.success { return Ok(found) }
    for l in out.stdout.split("\n") {
        let f = l.trim().split(" ")
        if f.len() == 2 { found.push(f) }
    }
    Ok(found)
}

// Unpacked and configured. A package waiting only on triggers is installed
// for every practical purpose.
fn is_installed(status: string) -> bool {
    status == "installed" || status == "triggers-pending" || status == "triggers-awaited"
}

// Anything dpkg has files for: absent means not-installed or config-files.
fn has_files(status: string) -> bool {
    status != "not-installed" && status != "config-files"
}

fn converged(params: Value) -> Result[bool, string] {
    let name = common::param_str(params, "name", "")
    let version = common::param_str(params, "version", "")
    let found = states(name)?
    if !common::want_present(params)? {
        return Ok(!found.any(|s| has_files(s[0])))
    }
    Ok(found.any(|s| is_installed(s[0]) && (version == "" || s[1] == version)))
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    if converged(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let name = common::param_str(params, "name", "")
    let version = common::param_str(params, "version", "")
    // A hold makes apt refuse to change the package at all, pinned version
    // or removal alike. The hold is the caller's own explicit lock, so it is
    // reported rather than overridden.
    if common::held(name)? {
        return Err(name + " is held (apt-mark hold), so apt will not change it; release the hold first with linux_apt.hold ensure = :absent")
    }
    if common::want_present(params)? {
        let target = if version != "" { name + "=" + version } else { name }
        // A pin below the installed version is a downgrade, which apt-get
        // refuses under -y without --allow-downgrades.
        common::run("apt-get install " + target, common::apt_get("install --allow-downgrades " + common::q(target)))?
    } else {
        common::run("apt-get remove " + name, common::apt_get("remove " + common::q(name)))?
    }
    Ok(ApplyResult::Success)
}
