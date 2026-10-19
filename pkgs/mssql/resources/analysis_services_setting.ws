use value
use sys
use log
use common
use ssas
use xmlfile

// One msmdsrv.ini setting of an Analysis Services instance, named as SSMS
// Server Properties shows it (ThreadPool\Process\MaxThreads). The file is
// edited in place with its formatting kept (lib/xmlfile.ws), and the service
// restarts only when the value changed.

struct Want {
    inst: string,
    ini: string,
    xpath: string,
    value: string,
}

fn want(params: Value) -> Result[Want, string] {
    if sys::family() != "windows" { return Err("mssql.analysis_services_setting is Windows only") }
    let inst = common::param_str(params, "instance", "MSSQLSERVER")
    if inst == "" { return Err("'instance' must not be empty (MSSQLSERVER is the default instance)") }
    common::check_instance(inst)?
    let xp = ssas::setting_xpath(common::require(params, "setting")?)?
    let v = common::param_str(params, "value", "")
    common::no_newlines("value", v)?
    Ok(Want { inst: inst, ini: ssas::ini_path(inst)?, xpath: xp, value: v })
}

fn check(params: Value) -> Result[CheckResult, string] {
    let w = want(params)?
    let have = xmlfile::read_values(w.ini, [w.xpath])?
    let cur = if let Some(o) = have.get(w.xpath) { o } else { None }
    match cur {
        Some(v) => if v == w.value { Ok(CheckResult::AlreadyConfigured) } else {
            log::info(w.xpath + " is '" + v + "', want '" + w.value + "'")
            Ok(CheckResult::NotConfigured)
        },
        None => Ok(CheckResult::NotConfigured)
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    let changed = xmlfile::write_values(w.ini, [[w.xpath, w.value]])?
    if !changed { return Ok(ApplyResult::Success) }
    log::info("set " + w.xpath + " = " + w.value + " in " + w.ini)
    if common::param_bool(params, "restart", true) {
        ssas::restart(w.inst)?
    } else {
        log::warn("the new value takes effect when " + ssas::service_name(w.inst) + " restarts")
    }
    Ok(ApplyResult::Success)
}
