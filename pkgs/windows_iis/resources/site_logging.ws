use value
use common
use section

// ---------------------------------------------------------------------------
// A site's logFile element.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let site = common::param_str(params, "site", "")
    if site == "" { return Err("missing 'site' parameter") }
    Ok("system.applicationHost/sites/site[@name='" + common::xp(site)? + "']")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "logFile.enabled", "bool"],
        ["directory", "logFile.directory", "str"],
        ["format", "logFile.logFormat", "sym"],
        ["period", "logFile.period", "sym"],
        ["truncate_size", "logFile.truncateSize", "int"],
        ["local_time_rollover", "logFile.localTimeRollover", "bool"],
        ["log_ext_file_flags", "logFile.logExtFileFlags", "flags"],
        ["log_target", "logFile.logTargetW3C", "sym"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["format", "iis", "IIS"],
        ["format", "ncsa", "NCSA"],
        ["format", "w3c", "W3C"],
        ["format", "custom", "Custom"],
        ["period", "max_size", "MaxSize"],
        ["period", "daily", "Daily"],
        ["period", "weekly", "Weekly"],
        ["period", "monthly", "Monthly"],
        ["period", "hourly", "Hourly"],
        ["log_target", "file", "File"],
        ["log_target", "etw", "ETW"],
        ["log_target", "etw_and_file", "File,ETW"],
    ] }

fn spec(params: Value) -> Result[SectionSpec, string] {
    Ok(SectionSpec { filter: section(params)?, scope: scope(params)?, attrs: attrs(), syms: sym_map(), extra: [] })
}

fn check(params: Value) -> Result[CheckResult, string] {
    section::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    section::apply(params, spec(params)?)?
    Ok(ApplyResult::Success)
}
