use value
use common

fn validate(params: Value) -> Result[unit, string] {
    common::operand("name", common::param_str(params, "name", ""))?
    let version = common::param_str(params, "version", "")
    if version != "" { common::operand("version", version)? }
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

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let name = common::param_str(params, "name", "")
    let version = common::param_str(params, "version", "")
    let bin = common::dnf_bin()?
    if common::want_present(params)? {
        let target = if version != "" { name + "-" + version } else { name }
        common::run(bin + " install " + target, bin + " install -y " + common::q(target))?
        // dnf and dnf5 install an exact older version as a downgrade; yum
        // and microdnf report it already installed and need downgrade.
        if version != "" && !converged(params)? {
            common::run(bin + " downgrade " + target, bin + " downgrade -y " + common::q(target))?
        }
        return Ok(ApplyResult::Success)
    }
    // Remove what name resolved to, by package name: a capability or path
    // is not something every front-end's remove accepts.
    let names = common::provider_names(common::providers(name)?)
    if names.is_empty() { return Ok(ApplyResult::Success) }
    if !common::param_bool(params, "remove_dependents", false) { common::guard_dependents(names)? }
    common::run(bin + " remove " + names.join(" "), bin + " remove -y " + common::quoted(names))?
    Ok(ApplyResult::Success)
}
