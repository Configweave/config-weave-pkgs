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

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn product_present(product_id: string) -> Result[bool, string] {
    let base = "\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    let wow = "\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    if registry::key_exists("HKLM" + base + product_id)? { return Ok(true) }
    Ok(registry::key_exists("HKLM" + wow + product_id)?)
}

// Idempotence guard: a `creates` path, or a product_id uninstall key.
fn done(params: Value) -> Result[bool, string] {
    let creates = param_str(params, "creates", "")
    if creates != "" { return Ok(fs::exists(creates)) }
    let product_id = param_str(params, "product_id", "")
    if product_id != "" { return product_present(product_id) }
    Err("exe_installer needs an idempotence guard: set 'creates' or 'product_id'")
}

fn check(params: Value) -> Result[CheckResult, string] {
    if done(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let src = param_str(params, "path", "")
    let args = param_str(params, "args", "")
    if src == "" { return Err("missing 'path' parameter") }
    let local = if src.starts_with("http") {
        let f = path::join(fs::temp_dir()?, "config-weave-installer.exe")
        http::download(src, f, Value::Null)?
        f
    } else {
        src
    }
    let alist = if args != "" { " -ArgumentList " + ps_q(args) } else { "" }
    let script = "$c = (Start-Process -FilePath " + ps_q(local) + alist + " -Wait -PassThru).ExitCode; exit $c"
    let out = shell::powershell(script, Value::Null)?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err("installer exited " + str(out.code) + ": " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
