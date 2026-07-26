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

fn param_list(params: Value, key: string) -> List[string] {
    let items: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs {
                if let Some(s) = x.as_string() { items.push(s) }
            }
        }
    }
    items
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// The Uninstall key (64- or 32-bit view) registering this product, if any.
// product_id is probed first; some installers register under an alternate
// package_code GUID instead, so that is probed in the same locations.
fn uninstall_key(params: Value) -> Result[Option[string], string] {
    let base = "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    let wow = "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    let ids = [param_str(params, "product_id", "")]
    let package_code = param_str(params, "package_code", "")
    if package_code != "" { ids.push(package_code) }
    for id in ids {
        if registry::key_exists(base + id)? { return Ok(Some(base + id)) }
        if registry::key_exists(wow + id)? { return Ok(Some(wow + id)) }
    }
    Ok(None)
}

fn run_msiexec(argline: string) -> Result[ApplyResult, string] {
    let script = "$c = (Start-Process -FilePath 'msiexec.exe' -ArgumentList " + ps_q(argline) + " -Wait -PassThru).ExitCode; exit $c"
    let out = shell::powershell(script, Value::Null)?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err("msiexec exited " + str(out.code) + ": " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

// Fetch a URL transform to a temp file; local paths pass through.
fn local_transform(src: string, n: int) -> Result[string, string] {
    if !src.starts_with("http") { return Ok(src) }
    let f = path::join(fs::temp_dir()?, "config-weave-transform-" + str(n) + ".mst")
    http::download(src, f, Value::Null)?
    Ok(f)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let product_id = param_str(params, "product_id", "")
    if product_id == "" { return Err("missing 'product_id' parameter (the MSI ProductCode)") }
    let found = uninstall_key(params)?
    if !want_present(params)? {
        if found.is_some() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if let Some(k) = found {
        // Installed but at the wrong version: re-run /i to upgrade.
        let want = param_str(params, "version", "")
        if want != "" {
            if let Some(have) = registry::read(k, "DisplayVersion")? {
                if have.as_string().unwrap_or("") != want { return Ok(CheckResult::NotConfigured) }
            } else {
                return Ok(CheckResult::NotConfigured)
            }
        }
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let product_id = param_str(params, "product_id", "")
    if product_id == "" { return Err("missing 'product_id' parameter (the MSI ProductCode)") }
    if !want_present(params)? {
        return run_msiexec("/x \"" + product_id + "\" /qn /norestart")
    }
    let src = param_str(params, "path", "")
    if src == "" { return Err("missing 'path' parameter") }
    let local = if src.starts_with("http") {
        let f = path::join(fs::temp_dir()?, "config-weave-installer.msi")
        http::download(src, f, Value::Null)?
        f
    } else {
        src
    }
    let mst: List[string] = []
    let n = [0]
    for t in param_list(params, "transforms") {
        let cur = n.get(0).unwrap_or(0)
        n.set(0, cur + 1)
        mst.push(local_transform(t, cur)?)
    }
    let targ = if mst.is_empty() { "" } else { " TRANSFORMS=\"" + mst.join(";") + "\"" }
    let props = [""]
    for p in param_list(params, "properties") {
        props.set(0, props.get(0).unwrap_or("") + " " + p)
    }
    run_msiexec("/i \"" + local + "\" /qn /norestart" + targ + props.get(0).unwrap_or(""))
}
