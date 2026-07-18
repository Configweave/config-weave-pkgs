use value
use fs
use path
use http
use shell
use registry

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// Installed when every configured marker is satisfied: an install_path that
// exists and/or an install_reg key that exists. At least one must be set.
fn installed(params: Value) -> Result[bool, string] {
    let install_path = param_str(params, "install_path", "")
    let install_reg = param_str(params, "install_reg", "")
    if install_path == "" && install_reg == "" {
        return Err("exe_installer needs a detection marker: set 'install_path' or 'install_reg'")
    }
    if install_path != "" && !fs::exists(install_path) { return Ok(false) }
    if install_reg != "" && !registry::key_exists(install_reg)? { return Ok(false) }
    Ok(true)
}

// DisplayVersion under install_reg matches the wanted version. Only
// meaningful when both 'version' and 'install_reg' are set.
fn version_matches(params: Value) -> Result[bool, string] {
    let want = param_str(params, "version", "")
    let install_reg = param_str(params, "install_reg", "")
    if want == "" || install_reg == "" { return Ok(true) }
    if let Some(have) = registry::read(install_reg, "DisplayVersion")? {
        return Ok(have.as_string().unwrap_or("") == want)
    }
    Ok(false)
}

// Start-Process an installer/uninstaller and map its exit code.
fn run_installer(exe: string, args: string, what: string) -> Result[ApplyResult, string] {
    let alist = if args != "" { " -ArgumentList " + ps_q(args) } else { "" }
    let script = "$c = (Start-Process -FilePath " + ps_q(exe) + alist + " -Wait -PassThru).ExitCode; exit $c"
    let out = shell::powershell(script, Value::Null)?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(what + " exited " + str(out.code) + ": " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let is_in = installed(params)?
    if !want_present(params)? {
        if is_in { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !is_in { return Ok(CheckResult::NotConfigured) }
    // Installed but at the wrong version: re-run the installer to upgrade.
    if !version_matches(params)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if !want_present(params)? {
        if !installed(params)? { return Ok(ApplyResult::Success) }
        let un = param_str(params, "uninstall_path", "")
        if un == "" { return Err("ensure = :absent needs 'uninstall_path' to remove the install") }
        return run_installer(un, param_str(params, "uninstall_args", ""), "uninstaller")
    }
    let src = param_str(params, "path", "")
    if src == "" { return Err("missing 'path' parameter") }
    let local = if src.starts_with("http") {
        let f = path::join(fs::temp_dir()?, "config-weave-installer.exe")
        http::download(src, f, Value::Null)?
        f
    } else {
        src
    }
    run_installer(local, param_str(params, "args", ""), "installer")
}
