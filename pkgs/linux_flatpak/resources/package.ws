use value
use common

fn kind(params: Value) -> Result[string, string] {
    let k = common::param_str(params, "kind", "app")
    if k == "app" || k == "runtime" { return Ok(k) }
    Err("invalid 'kind' value '" + k + "' (expected :app or :runtime)")
}

fn validate(params: Value, present: bool) -> Result[unit, string] {
    common::ident("id", common::param_str(params, "id", ""))?
    if present { common::ident("remote", common::param_str(params, "remote", ""))? }
    let k = kind(params)?
    let s = common::scope(params)?
    Ok(())
}

// The remote each installed branch of id came from, in this installation.
fn origins(params: Value) -> Result[List[string], string] {
    let id = common::param_str(params, "id", "")
    let cmd = common::flatpak(common::scope(params)?, "list --" + kind(params)? + " --columns=application,origin")
    let out = common::output("flatpak list", cmd)?
    let found = []
    for l in out.stdout.split("\n") {
        let f = l.split("\t")
        if f.len() >= 2 && f[0] == id { found.push(f[1].trim()) }
    }
    Ok(found)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let o = origins(params)?
    let remote = common::param_str(params, "remote", "")
    let ok = if present { o.len() > 0 && o.all(|r| r == remote) } else { o.len() == 0 }
    if ok { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let inst = common::scope(params)?
    let id = common::q(common::param_str(params, "id", ""))
    let k = "--" + kind(params)? + " "
    if !present {
        common::run("flatpak uninstall", common::flatpak(inst, "uninstall -y --noninteractive " + k + id))?
        return Ok(ApplyResult::Success)
    }
    // Installed from another remote: --reinstall uninstalls it and installs
    // it again from this one.
    let again = if origins(params)?.len() > 0 { "--reinstall " } else { "" }
    let remote = common::q(common::param_str(params, "remote", ""))
    common::run("flatpak install", common::flatpak(inst, "install -y --noninteractive " + again + k + remote + " " + id))?
    Ok(ApplyResult::Success)
}
