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

// An MSI ProductCode appears as an Uninstall subkey (64- or 32-bit view).
fn product_present(product_id: string) -> Result[bool, string] {
    let base = "\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    let wow = "\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    if registry::key_exists("HKLM" + base + product_id)? { return Ok(true) }
    Ok(registry::key_exists("HKLM" + wow + product_id)?)
}

fn run_msiexec(argline: string) -> Result[ApplyResult, string] {
    let script = "$c = (Start-Process -FilePath 'msiexec.exe' -ArgumentList " + ps_q(argline) + " -Wait -PassThru).ExitCode; exit $c"
    let out = shell::powershell(script, Value::Null)?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err("msiexec exited " + str(out.code) + ": " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let product_id = param_str(params, "product_id", "")
    if product_id == "" { return Err("missing 'product_id' parameter (the MSI ProductCode)") }
    if product_present(product_id)? == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let product_id = param_str(params, "product_id", "")
    if product_id == "" { return Err("missing 'product_id' parameter (the MSI ProductCode)") }
    if !want_present(params)? {
        return run_msiexec("/x \"" + product_id + "\" /qn /norestart")
    }
    let src = param_str(params, "path", "")
    let args = param_str(params, "args", "")
    if src == "" { return Err("missing 'path' parameter") }
    let local = if src.starts_with("http") {
        let f = path::join(fs::temp_dir()?, "config-weave-installer.msi")
        http::download(src, f, Value::Null)?
        f
    } else {
        src
    }
    let extra = if args != "" { " " + args } else { "" }
    run_msiexec("/i \"" + local + "\" /qn /norestart" + extra)
}
