use value
use common
use config_file

// LogLevel is parsed as a PSLevel. PSLevel has no "None", and an unparseable
// name silently means Informational, so :none is written as LogAlways — the
// level that admits only events logged unconditionally.
fn level_name(symbol: string) -> string {
    if symbol == "none" { return "LogAlways" }
    common::pascal(symbol)
}

fn checked_names(label: string, values: List[string], allowed: List[string]) -> Result[List[string], string] {
    let out: List[string] = []
    for v in values {
        let name = v.trim()
        let matched = ""
        for a in allowed {
            if a.to_lower() == name.to_lower() { matched = a }
        }
        if matched == "" { return Err("'" + label + "' value '" + v + "' is not one of " + allowed.join(", ")) }
        out.push(matched)
    }
    Ok(out)
}

// PowerShell reads LogChannels and LogKeywords as one string split on
// spaces, commas or pipes — a JSON array is not read at all.
fn desired_doc(params: Value, doc: Value) -> Result[Value, string] {
    if common::param_str(params, "path", "") == "" && common::param_str(params, "scope", "all_users") != "all_users" {
        return Err("PowerShell reads the logging settings only from the all-users $PSHOME/powershell.config.json; scope must be :all_users")
    }
    let updated = doc
    let level = common::param_str(params, "log_level", "unmanaged")
    if level != "unmanaged" {
        updated = config_file::put(updated, "LogLevel", Value::String(level_name(level)))
    }
    let identity = common::param_str(params, "log_identity", "")
    if identity != "" {
        updated = config_file::put(updated, "LogIdentity", Value::String(identity))
    }
    let manage = common::param_bool(params, "manage_lists", false)
    let channels = checked_names("log_channels", common::param_list(params, "log_channels"), ["Operational", "Analytic"])?
    if manage || !channels.is_empty() {
        updated = if channels.is_empty() { config_file::drop_key(updated, "LogChannels") } else { config_file::put(updated, "LogChannels", Value::String(channels.join(", "))) }
    }
    let keyword_names = ["Runspace", "Pipeline", "Protocol", "Transport", "Host", "Cmdlet", "Serializer", "Session", "ManagedPlugin"]
    let keywords = checked_names("log_keywords", common::param_list(params, "log_keywords"), keyword_names)?
    if manage || !keywords.is_empty() {
        updated = if keywords.is_empty() { config_file::drop_key(updated, "LogKeywords") } else { config_file::put(updated, "LogKeywords", Value::String(keywords.join(", "))) }
    }
    Ok(updated)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let resolved = config_file::config_path(params)?
    if resolved.is_none() { return Ok(CheckResult::NotConfigured) }
    // An unreadable file is drift; apply says why it cannot rewrite it.
    let read = config_file::read_doc(resolved.unwrap())
    if read.is_err() { return Ok(CheckResult::NotConfigured) }
    let doc = read.unwrap()
    if config_file::same_value(desired_doc(params, doc)?, doc) { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = config_file::require_config_path(params)?
    let doc = config_file::read_doc(file)?
    config_file::write_doc(file, desired_doc(params, doc)?)?
    Ok(ApplyResult::Success)
}
