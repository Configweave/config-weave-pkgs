use value
use fs
use registry
use common
use vrange

// How long install markers may lag the installer's exit before the run is
// called a failure. Many uninstallers copy themselves to %TEMP%, re-launch
// and return at once.
fn settle_secs() -> int { 120 }

fn validate(params: Value) -> Result[unit, string] {
    common::want_present(params)?
    let install_path = common::param_str(params, "install_path", "")
    let install_reg = common::param_str(params, "install_reg", "")
    if install_path == "" && install_reg == "" {
        return Err("exe_installer needs a detection marker: set 'install_path' or 'install_reg'")
    }
    common::single_line("install_path", install_path)?
    common::single_line("install_reg", install_reg)?
    let version = common::param_str(params, "version", "")
    if version != "" && install_reg == "" {
        return Err("'version' is matched against the " + version_value(params) + " value under 'install_reg', so it needs 'install_reg' set")
    }
    vrange::validate("version", version)?
    let vv = version_value(params)
    if vv.trim() == "" { return Err("'version_value' must name a registry value, e.g. DisplayVersion") }
    common::single_line("version_value", vv)?
    common::validate_sha256(common::param_str(params, "sha256", ""))?
    common::validate_codes(params)?
    for label in ["path", "args", "uninstall_path", "uninstall_args"] {
        common::single_line(label, common::param_str(params, label, ""))?
    }
    Ok(())
}

// Installed when every configured marker is satisfied: an install_path
// that exists and/or an install_reg key that exists.
fn installed(params: Value) -> Result[bool, string] {
    let install_path = common::param_str(params, "install_path", "")
    let install_reg = common::param_str(params, "install_reg", "")
    if install_path != "" && !fs::exists(install_path) { return Ok(false) }
    if install_reg != "" && !registry::key_exists(install_reg)? { return Ok(false) }
    Ok(true)
}

fn version_value(params: Value) -> string { common::param_str(params, "version_value", "DisplayVersion") }

// Where the installed version is read, for messages.
fn version_source(params: Value) -> string { version_value(params) + " under " + common::param_str(params, "install_reg", "") }

// The installed version: the version_value value under install_reg, "" when
// that value is missing. A DWORD (some installers write one) reads as its
// decimal number.
fn installed_version(params: Value) -> Result[string, string] {
    if let Some(have) = registry::read(common::param_str(params, "install_reg", ""), version_value(params))? {
        if let Some(s) = have.as_string() { return Ok(s) }
        if let Some(n) = have.as_int() { return Ok(str(n)) }
    }
    Ok("")
}

fn version_matches(params: Value) -> Result[bool, string] {
    let want = common::param_str(params, "version", "")
    if vrange::any(want) { return Ok(true) }
    vrange::satisfies("exe_installer", installed_version(params)?, want, version_source(params))
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let is_in = installed(params)?
    if !common::want_present(params)? {
        if is_in { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !is_in { return Ok(CheckResult::NotConfigured) }
    // Installed but at the wrong version: re-run the installer to upgrade.
    if !version_matches(params)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

// Runs an installer or uninstaller and returns its exit code once
// success_codes/reboot_codes (and the built-in 0, 3010, 1641) say it did not
// fail. Any other code fails the step, naming the log file when `args`
// names one.
fn run(params: Value, exe: string, args: string, what: string) -> Result[int, string] {
    let out = common::start_process(exe, args)?
    if common::outcome(params, out.code)? != "fail" { return Ok(out.code) }
    let msg = common::failure(what + " '" + exe + "'", out)
    let log = common::log_arg(args)
    if log != "" { msg = msg + "; log: " + log }
    Err(msg)
}

fn exited(what: string, code: int) -> string { "the " + what + " exited " + common::code_str(code) }

// An UninstallString is a whole command line: a quoted or bare executable
// followed by its arguments. Returns [exe, args].
fn split_command(cmd: string) -> List[string] {
    let c = cmd.trim()
    if c.starts_with("\"") {
        let rest = c.slice(1, c.len())
        if let Some(e) = rest.find("\"") { return [rest.slice(0, e), rest.slice(e + 1, rest.len()).trim()] }
        return [rest, ""]
    }
    if let Some(i) = c.to_lower().find(".exe") { return [c.slice(0, i + 4), c.slice(i + 4, c.len()).trim()] }
    if let Some(i) = c.find(" ") { return [c.slice(0, i), c.slice(i + 1, c.len()).trim()] }
    [c, ""]
}

// MSI-based entries register `MsiExec.exe /I{GUID}`, which opens the
// maintenance UI; it becomes a silent /X.
fn quiet_msiexec(exe: string, args: string) -> string {
    let name = exe.to_lower()
    if !(name.ends_with("msiexec.exe") || name.ends_with("msiexec")) { return args }
    let a = args
    if a.to_upper().starts_with("/I") { a = "/X" + a.slice(2, a.len()) }
    if !a.to_lower().contains("/q") { a = a + " /qn /norestart" }
    a
}

// The uninstaller to run, as [exe, args, origin]: uninstall_path when set;
// else the install_reg key's QuietUninstallString, then UninstallString
// (with uninstall_args appended); else the installer itself with
// uninstall_args, for installers that double as their own uninstaller.
fn uninstaller(params: Value) -> Result[List[string], string] {
    let uargs = common::param_str(params, "uninstall_args", "")
    let upath = common::param_str(params, "uninstall_path", "")
    if upath != "" { return Ok([upath, uargs, "uninstall_path"]) }
    let reg = common::param_str(params, "install_reg", "")
    if reg != "" {
        for value in ["QuietUninstallString", "UninstallString"] {
            if let Some(v) = registry::read(reg, value)? {
                let line = v.as_string().unwrap_or("")
                if line.trim() != "" {
                    let parts = split_command(line)
                    let exe = parts.get(0).unwrap_or("")
                    let args = quiet_msiexec(exe, parts.get(1).unwrap_or(""))
                    if uargs != "" { args = (args + " " + uargs).trim() }
                    return Ok([exe, args, value + " under " + reg])
                }
            }
        }
    }
    let src = common::param_str(params, "path", "")
    if src != "" && uargs != "" { return Ok([src, uargs, "path"]) }
    Err("nothing to uninstall with: set 'uninstall_path', or 'install_reg' naming a key with an UninstallString, or 'path' with 'uninstall_args'")
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    if !common::want_present(params)? {
        // Nothing to remove: no uninstaller runs against software that is
        // not there.
        if !installed(params)? { return Ok(ApplyResult::Success) }
        let u = uninstaller(params)?
        let exe = u.get(0).unwrap_or("")
        let origin = u.get(2).unwrap_or("")
        let target = if common::is_url(exe) { common::local_file(exe, "", "uninstaller.exe")? } else { exe }
        let code = run(params, target, u.get(1).unwrap_or(""), "uninstaller from " + origin)?
        if common::outcome(params, code)? == "reboot" { return Ok(ApplyResult::RebootRequired) }
        if !common::wait_for_marker(false, settle_secs(), || installed(params))? {
            return Err(exited("uninstaller from " + origin, code) + ", but the install markers are still present after " + str(settle_secs()) + "s")
        }
        return Ok(ApplyResult::Success)
    }
    let src = common::param_str(params, "path", "")
    if src == "" { return Err("missing 'path' parameter (the installer to run)") }
    let exe = common::local_file(src, common::param_str(params, "sha256", ""), "installer.exe")?
    let code = run(params, exe, common::param_str(params, "args", ""), "installer")?
    if common::outcome(params, code)? == "reboot" { return Ok(ApplyResult::RebootRequired) }
    if !common::wait_for_marker(true, settle_secs(), || installed(params))? {
        return Err(exited("installer", code) + ", but the install markers are still missing after " + str(settle_secs()) + "s; check install_path/install_reg")
    }
    // The installer at path is what gets installed, whatever the range; one
    // that leaves a version outside it fails here.
    if !version_matches(params)? {
        return Err(exited("installer", code) + ", but " + version_source(params) + " is '" + installed_version(params)? + "', which does not satisfy version '" + common::param_str(params, "version", "") + "'")
    }
    Ok(ApplyResult::Success)
}
