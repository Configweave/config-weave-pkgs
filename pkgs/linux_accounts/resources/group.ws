use value
use shell
use common

// Local groups only: the entry is read from /etc/group, so a same-named
// LDAP/SSSD group neither satisfies :present nor blocks :absent.
fn group_entry(name: string) -> Result[Option[List[string]], string] {
    common::local_entry("/etc/group", name)
}

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::valid_account("name", name)?
    if common::param_int(params, "gid", 0) < 0 { return Err("'gid' must not be negative") }
    Ok(name)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let entry = group_entry(name)?
    if !common::want_present(params)? {
        if entry.is_some() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if let Some(e) = entry {
        let gid = common::param_int(params, "gid", 0)
        if gid > 0 && common::field(e, 2) != str(gid) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let entry = group_entry(name)?
    if !common::want_present(params)? {
        if entry.is_none() { return Ok(ApplyResult::Success) }
        // fails while the group is still some user's primary group — order
        // the user's removal first with `requires`
        common::run("groupdel " + name, "groupdel " + common::q(name))?
        return Ok(ApplyResult::Success)
    }
    let gid = common::param_int(params, "gid", 0)
    let gid_arg = if gid > 0 { " -g " + str(gid) } else { "" }
    if entry.is_none() {
        common::run("groupadd " + name, "groupadd" + gid_arg + " " + common::q(name))?
    } else if gid > 0 {
        // Files still owned by the old gid keep it; groupmod does not chown.
        common::run("groupmod " + name, "groupmod" + gid_arg + " " + common::q(name))?
    }
    Ok(ApplyResult::Success)
}
