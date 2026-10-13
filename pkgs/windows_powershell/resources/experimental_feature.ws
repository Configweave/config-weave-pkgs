use value
use common
use config_file

fn desired_features(params: Value, current: List[string]) -> Result[List[string], string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if common::want_present(params)? {
        if current.contains(name) { return Ok(current) }
        let added: List[string] = []
        for feature in current { added.push(feature) }
        added.push(name)
        return Ok(added)
    }
    let kept: List[string] = []
    for feature in current {
        if feature != name { kept.push(feature) }
    }
    Ok(kept)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    let resolved = config_file::config_path(params)?
    if resolved.is_none() {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let read = config_file::read_doc(resolved.unwrap())
    if read.is_err() { return Ok(CheckResult::NotConfigured) }
    let current = config_file::list_at(read.unwrap(), "ExperimentalFeatures")
    if desired_features(params, current)? == current { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = config_file::require_config_path(params)?
    let doc = config_file::read_doc(file)?
    let features = desired_features(params, config_file::list_at(doc, "ExperimentalFeatures"))?
    let updated = if features.is_empty() {
        config_file::drop_key(doc, "ExperimentalFeatures")
    } else {
        config_file::put(doc, "ExperimentalFeatures", config_file::string_list(features))
    }
    config_file::write_doc(file, updated)?
    Ok(ApplyResult::Success)
}
