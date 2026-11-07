use value
use regex
use version
use common

struct Want {
    name: string,
    version: string,
    present: bool,
}

fn want(params: Value) -> Result[Want, string] {
    let name = common::param_str(params, "name", "")
    common::dist_name(name)?
    let v = common::param_str(params, "version", "")
    if v != "" { common::exact_version(v)? }
    let present = common::want_present(params)?
    Ok(Want { name: name, version: v, present: present })
}

// Versions are compared as strings, except that two plain release numbers
// that differ only by trailing zeros (1.0 and 1.0.0) are the same release,
// as pip itself treats them: otherwise a pin of 1.0.0 against an installed
// 1.0 could never converge.
fn same_version(installed: string, wanted: string) -> bool {
    if installed == wanted { return true }
    let plain = "^[0-9]+(\\.[0-9]+)*$"
    if regex::is_match(plain, installed) && regex::is_match(plain, wanted) {
        if let Ok(c) = version::compare(installed, wanted) { return c == 0 }
    }
    false
}

fn converged(w: Want, installed: string) -> bool {
    if !w.present { return installed == "" }
    installed != "" && (w.version == "" || same_version(installed, w.version))
}

// Read-only: validates, selects the environment and reads its installed
// metadata with `pip list`. Nothing is installed and no index is contacted.
fn check(params: Value) -> Result[CheckResult, string] {
    let w = want(params)?
    let p = common::select(params)?
    let installed = common::installed(p, w.name)?
    if converged(w, installed) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

// Install with pip's own resolver (dependencies included) from whatever
// index or find-links the environment configures. Removal uninstalls this
// distribution only; dependencies it pulled in stay. A pip error, including
// a PEP 668 "externally-managed-environment" refusal, is returned as it is:
// no --break-system-packages, --user or --force-reinstall is ever added.
fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    let p = common::select(params)?
    let installed = common::installed(p, w.name)?
    if converged(w, installed) { return Ok(ApplyResult::Success) }
    if w.present {
        let req = if w.version != "" { w.name + "==" + w.version } else { w.name }
        let out = common::pip(p, "install", req)?
        if !out.success { return Err(common::cmd_err(p.label + " install " + req, out)) }
        let now = common::installed(p, w.name)?
        if !converged(w, now) {
            let got = if now == "" { "not installed" } else { "version " + now }
            return Err(p.label + " install " + req + " succeeded, but " + w.name + " is " + got + " in that environment")
        }
    } else {
        let out = common::pip(p, "uninstall -y", w.name)?
        if !out.success { return Err(common::cmd_err(p.label + " uninstall " + w.name, out)) }
    }
    Ok(ApplyResult::Success)
}
