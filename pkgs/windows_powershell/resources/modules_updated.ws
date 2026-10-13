use value
use common
use psget

fn stamp(params: Value) -> string {
    common::stamp_path(params, "powershell-modules-updated", [
        common::resolved_edition(common::param_str(params, "edition", "auto")),
        common::param_str(params, "scope", "current_user"),
        common::sorted(common::param_list(params, "names")).join(","),
        str(common::param_bool(params, "prerelease", false))
    ])
}

fn check(params: Value) -> Result[CheckResult, string] {
    if common::stamp_fresh(stamp(params), params)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let edition = common::param_str(params, "edition", "auto")
    if !common::ps_installed(edition) { return Err(common::not_installed(edition)) }
    let kind = psget::provider(params)?
    let names = common::param_list(params, "names")
    for n in names { common::no_wildcards("names", n)? }
    let scope = common::pascal(common::param_str(params, "scope", "current_user"))
    let prerelease = common::param_bool(params, "prerelease", false)
    let trust = common::param_bool(params, "trust_repository", false)

    let script = ""
    if kind == "psresourceget" {
        let target = if names.is_empty() { "-Name '*'" } else { "-Name " + common::ps_list(names) }
        let args = " " + target + " -Scope " + scope
        if trust { args = args + " -TrustRepository" }
        if prerelease { args = args + " -Prerelease" }
        script = psget::import_line(kind) + "Update-PSResource" + args
    } else {
        // Update-Module has no per-call trust switch; -Force is what skips the
        // untrusted-repository prompt, so it follows trust_repository.
        let args = if names.is_empty() { "" } else { " -Name " + common::ps_list(names) }
        if trust { args = args + " -Force" }
        if prerelease { args = args + " -AllowPrerelease" }
        script = psget::v2_bootstrap() + "Update-Module" + args
    }

    let out = common::run_ps_streaming(edition, script, 1800)?
    if !out.success { return Err(common::failure("updating modules", out)) }
    common::touch_stamp(stamp(params), "powershell-modules")?
    Ok(ApplyResult::Success)
}
