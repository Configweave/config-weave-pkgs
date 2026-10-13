use value
use fs
use shell
use common

// Local users only: the entry is read from /etc/passwd, because id and
// getent also see LDAP/SSSD users that useradd, usermod and userdel cannot
// touch. Fields: name:x:uid:gid:gecos:home:shell.
fn user_entry(name: string) -> Result[Option[List[string]], string] {
    common::local_entry("/etc/passwd", name)
}

fn path_param(params: Value, key: string) -> Result[string, string] {
    let v = common::param_str(params, key, "")
    if v == "" { return Ok(v) }
    common::one_line(key, v)?
    if !v.starts_with("/") || v.contains(":") { return Err("'" + key + "' must be an absolute path without ':'") }
    Ok(v)
}

struct Want {
    name: string,
    uid: int,
    group: string,
    home: string,
    shell: string,
    system: bool,
}

fn wanted(params: Value) -> Result[Want, string] {
    let name = common::param_str(params, "name", "")
    common::valid_account("name", name)?
    let uid = common::param_int(params, "uid", 0)
    if uid < 0 { return Err("'uid' must not be negative") }
    let group = common::param_str(params, "group", "")
    if group != "" && !common::is_digits(group) { common::valid_account("group", group)? }
    Ok(Want {
        name: name,
        uid: uid,
        group: group,
        home: path_param(params, "home")?,
        shell: path_param(params, "shell")?,
        system: common::param_bool(params, "system", false),
    })
}

// The gid a `group` param names: digits are the gid itself; a name is looked
// up locally, then through NSS (a primary group may live in a directory).
// Empty when the group does not exist yet.
fn group_gid(group: string) -> Result[string, string] {
    if common::is_digits(group) { return Ok(group) }
    if let Some(e) = common::local_entry("/etc/group", group)? { return Ok(common::field(e, 2)) }
    let out = shell::bash("getent group " + common::q(group), Value::Null)?
    if !out.success { return Ok("") }
    Ok(common::field(out.stdout.trim().split(":"), 2))
}

// UID_MIN from /etc/login.defs: ids below it are system accounts.
fn uid_min() -> int {
    if !fs::is_file("/etc/login.defs") { return 1000 }
    for line in fs::read("/etc/login.defs").unwrap_or("").split("\n") {
        let t = line.trim().replace("\t", " ")
        if !t.starts_with("UID_MIN ") { continue }
        if let Some(n) = t.slice(8, t.len()).trim().parse_int() { return n }
    }
    1000
}

// `system` only picks the id range at creation and cannot be changed later
// (that would mean a new uid). When `uid` is set it decides the range; when
// it is not, an existing account on the wrong side of UID_MIN is an error
// rather than drift nothing can fix. root (uid 0) passes either way.
fn system_drift(w: Want, entry: List[string]) -> Result[unit, string] {
    if w.uid > 0 { return Ok(()) }
    let uid = common::field(entry, 2).parse_int().unwrap_or(0)
    if uid == 0 { return Ok(()) }
    let is_system = uid < uid_min()
    if is_system != w.system {
        let have = if is_system { "a system account" } else { "a regular account" }
        return Err("user " + w.name + " is " + have + " (uid " + str(uid) + "); 'system' = " + str(w.system) + " cannot be reconciled on an existing user")
    }
    Ok(())
}

// The usermod flags that bring an existing entry to `w`; empty when it
// already matches.
fn usermod_args(w: Want, entry: List[string]) -> Result[string, string] {
    let args = ""
    if w.uid > 0 && common::field(entry, 2) != str(w.uid) { args = args + " -u " + str(w.uid) }
    if w.group != "" {
        let gid = group_gid(w.group)?
        if gid == "" || common::field(entry, 3) != gid { args = args + " -g " + common::q(w.group) }
    }
    if w.home != "" && common::field(entry, 5) != w.home {
        // usermod -m refuses a target that already exists, after it has
        // already rewritten passwd; adopt an existing directory as it is
        // and leave the old home where it was.
        let mv = if fs::exists(w.home) { "" } else { " -m" }
        args = args + " -d " + common::q(w.home) + mv
    }
    if w.shell != "" && common::field(entry, 6) != w.shell { args = args + " -s " + common::q(w.shell) }
    Ok(args)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let w = wanted(params)?
    let entry = user_entry(w.name)?
    if !common::want_present(params)? {
        if entry.is_some() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if let Some(e) = entry {
        system_drift(w, e)?
        if usermod_args(w, e)? == "" { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = wanted(params)?
    let entry = user_entry(w.name)?
    if !common::want_present(params)? {
        if entry.is_none() { return Ok(ApplyResult::Success) }
        let flag = if common::param_bool(params, "remove_home", false) { " -r" } else { "" }
        let out = shell::bash("userdel" + flag + " " + common::q(w.name), Value::Null)?
        if !out.success {
            // userdel -r exits non-zero on an already-missing home or mail
            // spool; trust the re-probe — gone means done
            if user_entry(w.name)?.is_none() { return Ok(ApplyResult::Success) }
            return Err(common::cmd_err("userdel " + w.name, out))
        }
        return Ok(ApplyResult::Success)
    }
    if let Some(e) = entry {
        system_drift(w, e)?
        let args = usermod_args(w, e)?
        if args != "" { common::run("usermod " + w.name, "usermod" + args + " " + common::q(w.name))? }
        return Ok(ApplyResult::Success)
    }
    let cmd = "useradd -m"
    if w.uid > 0 { cmd = cmd + " -u " + str(w.uid) }
    if w.group != "" { cmd = cmd + " -g " + common::q(w.group) }
    if w.home != "" { cmd = cmd + " -d " + common::q(w.home) }
    if w.shell != "" { cmd = cmd + " -s " + common::q(w.shell) }
    if w.system { cmd = cmd + " --system" }
    common::run("useradd " + w.name, cmd + " " + common::q(w.name))?
    Ok(ApplyResult::Success)
}
