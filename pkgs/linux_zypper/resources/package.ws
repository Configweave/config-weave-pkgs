use value
use common

fn validate(params: Value) -> Result[unit, string] {
    common::operand("name", common::param_str(params, "name", ""))?
    let version = common::param_str(params, "version", "")
    if version != "" {
        common::exact_pin("version", version)?
        common::operand("version", version)?
    }
    Ok(())
}

fn converged(params: Value) -> Result[bool, string] {
    let version = common::param_str(params, "version", "")
    let found = common::providers(common::param_str(params, "name", ""))?
    if !common::want_present(params)? { return Ok(found.is_empty()) }
    Ok(found.any(|p| version == "" || common::version_matches(p, version)))
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    if converged(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

// Accepting unknown repository keys weakens trust, so it is opt-in.
fn global(params: Value) -> string {
    if common::param_bool(params, "gpg_auto_import_keys", false) { "--gpg-auto-import-keys " } else { "" }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let name = common::param_str(params, "name", "")
    let version = common::param_str(params, "version", "")
    let code = if common::want_present(params)? {
        // name=version matches that version with any release, and
        // --oldpackage lets it be older than the installed one.
        let args = if version != "" {
            "install --auto-agree-with-licenses --oldpackage " + common::q(name + "=" + version)
        } else {
            "install --auto-agree-with-licenses " + common::q(name)
        }
        common::zypper("zypper install " + name, global(params) + args, true)?
    } else {
        // Remove what name resolved to, by package name. Removal needs no
        // repository metadata, so none is loaded or refreshed.
        let names = common::provider_names(common::providers(name)?)
        if names.is_empty() { return Ok(ApplyResult::Success) }
        if !common::param_bool(params, "remove_dependents", false) { common::guard_dependents(names)? }
        common::zypper("zypper remove " + names.join(" "), "--disable-repositories remove " + common::quoted(names), true)?
    }
    if code == 102 { return Ok(ApplyResult::RebootRequired) }
    Ok(ApplyResult::Success)
}
