use value
use fs
use data
use common

fn validate(params: Value, present: bool) -> Result[unit, string] {
    common::file_name("alias", common::param_str(params, "alias", ""))?
    if !present { return Ok(()) }
    let url = common::param_str(params, "url", "")
    if url == "" { return Err("missing 'url' parameter") }
    common::operand("url", url)?
    let name = common::param_str(params, "name", "")
    if name.contains("\n") || name.contains("\r") { return Err("'name' must not contain line breaks") }
    Ok(())
}

fn flag(section: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = section.get(key) {
        if let Some(s) = v.as_string() { return s == "1" }
    }
    fallback
}

fn text(section: Value, key: string) -> string {
    if let Some(v) = section.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

// The repository as zypper stores it: its section in whichever
// /etc/zypp/repos.d file defines the alias. Defaults are zypper's for a
// key the file leaves out: enabled, no autorefresh, gpgcheck from
// zypp.conf (on), and the alias as the name.
fn current(alias: string) -> Result[Option[Map[string, string]], string] {
    if !fs::is_dir("/etc/zypp/repos.d") { return Ok(None) }
    for f in fs::glob("/etc/zypp/repos.d/*.repo")? {
        let parsed = if let Ok(t) = fs::read(f) { data::ini_parse(t) } else { continue }
        let ini = if let Ok(v) = parsed { v } else { continue }
        if let Some(sec) = ini.get(alias) {
            let name = if text(sec, "name") == "" { alias } else { text(sec, "name") }
            return Ok(Some(#{
                "url": text(sec, "baseurl"),
                "name": name,
                "enabled": str(flag(sec, "enabled", true)),
                "autorefresh": str(flag(sec, "autorefresh", false)),
                "gpgcheck": str(flag(sec, "gpgcheck", true)),
            }))
        }
    }
    Ok(None)
}

fn desired(params: Value) -> Map[string, string] {
    let alias = common::param_str(params, "alias", "")
    let name = common::param_str(params, "name", "")
    #{
        "url": common::param_str(params, "url", ""),
        "name": if name == "" { alias } else { name },
        "enabled": str(common::param_bool(params, "enabled", true)),
        "autorefresh": str(common::param_bool(params, "autorefresh", true)),
        "gpgcheck": str(common::param_bool(params, "gpgcheck", true)),
    }
}

fn same(a: Map[string, string], b: Map[string, string]) -> bool {
    for k in ["url", "name", "enabled", "autorefresh", "gpgcheck"] {
        if a.get(k) != b.get(k) { return false }
    }
    true
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let cur = current(common::param_str(params, "alias", ""))?
    if !present {
        if cur.is_some() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if let Some(c) = cur {
        if same(c, desired(params)) { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let alias = common::param_str(params, "alias", "")
    let cur = current(alias)?
    if !present {
        if cur.is_some() {
            let code = common::zypper("zypper removerepo " + alias, "removerepo " + common::q(alias), false)?
        }
        return Ok(ApplyResult::Success)
    }
    let want = desired(params)
    let on = |k: string| want.get(k) == Some("true")
    let opts = "--name " + common::q(want.get("name").unwrap_or(alias)) +
        (if on("enabled") { " --enable" } else { " --disable" }) +
        (if on("autorefresh") { " --refresh" } else { " --no-refresh" }) +
        (if on("gpgcheck") { " --gpgcheck" } else { " --no-gpgcheck" })
    if let Some(c) = cur {
        // modifyrepo cannot change the URL, so a moved repository is
        // removed and added again
        if c.get("url") == want.get("url") {
            common::zypper("zypper modifyrepo " + alias, "modifyrepo " + opts + " " + common::q(alias), false)?
            return Ok(ApplyResult::Success)
        }
        common::zypper("zypper removerepo " + alias, "removerepo " + common::q(alias), false)?
    }
    // addrepo has no --enable or --no-refresh; leaving them out is the same
    let add = opts.replace(" --enable", "").replace(" --no-refresh", "")
    // --no-check: do not probe the URL, so a repository can be declared
    // before it is reachable
    common::zypper("zypper addrepo " + alias, "addrepo --no-check " + add + " " + common::q(want.get("url").unwrap_or("")) + " " + common::q(alias), false)?
    Ok(ApplyResult::Success)
}
