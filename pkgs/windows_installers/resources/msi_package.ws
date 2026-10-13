use value
use fs
use path
use json
use registry
use common

fn uninstall_roots() -> List[string] {
    [
        "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\",
        "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    ]
}

fn ids(params: Value) -> List[string] {
    let out = [common::param_str(params, "product_id", "")]
    let alt = common::param_str(params, "alt_product_id", "")
    if alt != "" { out.push(alt) }
    out
}

// The Uninstall key registering this product and the GUID it was found
// under, as [key, guid]; empty when not installed. product_id is probed
// first, then alt_product_id, each in the 64- and 32-bit views.
fn found(params: Value) -> Result[List[string], string] {
    for id in ids(params) {
        for root in uninstall_roots() {
            if registry::key_exists(root + id)? { return Ok([root + id, id]) }
        }
    }
    Ok([])
}

fn display_version(key: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, "DisplayVersion")? { return Ok(v.as_string().unwrap_or("")) }
    Ok("")
}

fn validate(params: Value) -> Result[unit, string] {
    common::validate_guid("product_id", common::param_str(params, "product_id", ""))?
    let alt = common::param_str(params, "alt_product_id", "")
    if alt != "" { common::validate_guid("alt_product_id", alt)? }
    common::want_present(params)?
    common::quotable_path("path", common::param_str(params, "path", ""))?
    common::validate_sha256(common::param_str(params, "sha256", ""))?
    common::validate_version(common::param_str(params, "version", ""))?
    for t in common::param_list(params, "transforms") {
        common::quotable_path("transforms", t)?
        if t.contains(";") { return Err("a 'transforms' entry must not contain ';' (msiexec's separator), got '" + t + "'") }
    }
    // Each entry reaches the msiexec command line verbatim, so it must be
    // one PUBLIC_PROPERTY=value assignment.
    for p in common::param_list(params, "properties") {
        common::single_line("properties", p)?
        let eq = p.find("=")
        if eq.is_none() || eq.unwrap_or(0) == 0 { return Err("a 'properties' entry must be NAME=value, got '" + p + "'") }
        let name = p.slice(0, eq.unwrap_or(0))
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_."
        for c in name.chars() {
            if !allowed.contains(str(c)) { return Err("property name '" + name + "' must be an uppercase public property (A-Z, 0-9, '_', '.')") }
        }
    }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let hit = found(params)?
    if !common::want_present(params)? {
        if hit.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if hit.is_empty() { return Ok(CheckResult::NotConfigured) }
    let want = common::param_str(params, "version", "")
    if want != "" && display_version(hit.get(0).unwrap_or(""))? != want { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

// ProductCode and ProductVersion from the package's own Property table, so
// a mismatch with product_id or version is reported before msiexec runs
// rather than as a re-check that never converges.
fn msi_properties(file: string) -> Result[Value, string] {
    let script = "$i = New-Object -ComObject WindowsInstaller.Installer\n" +
        "$db = $i.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $i, @($env:CW_MSI, 0))\n" +
        "$r = @{{}}\n" +
        "foreach ($p in 'ProductCode', 'ProductVersion') {{\n" +
        "  $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @(\"SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$p'\"))\n" +
        "  $v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)\n" +
        "  $rec = $v.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $v, $null)\n" +
        "  $r[$p] = if ($rec) {{ $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }} else {{ '' }}\n" +
        "  $v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)\n" +
        "}}\n" +
        "ConvertTo-Json -Compress $r\n"
    let out = common::run_ps(script, #{ "CW_MSI": Value::String(file) })?
    if !out.success { return Err(common::failure("reading the MSI properties of '" + file + "'", out)) }
    json::parse(out.stdout.trim())
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn log_path(product_id: string) -> string {
    path::join(path::join(common::cache_dir(), "logs"), product_id.replace("{{", "").replace("}}", "") + ".log")
}

// msiexec with a verbose log; a failure quotes the log's error lines,
// since msiexec itself says nothing beyond the exit code. 1605 and 1614
// (unknown or already uninstalled product) are success for /x.
fn run_msiexec(argline: string, product_id: string, removing: bool) -> Result[ApplyResult, string] {
    let log = log_path(product_id)
    fs::mkdir(path::parent(log))?
    let out = common::start_process("msiexec.exe", argline + " /L*V \"" + log + "\"")?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if out.code == 0 { return Ok(ApplyResult::Success) }
    if removing && (out.code == 1605 || out.code == 1614) { return Ok(ApplyResult::Success) }
    let detail = common::run_ps(
        "if (Test-Path -LiteralPath $env:CW_LOG) {{ (Select-String -LiteralPath $env:CW_LOG -Pattern 'Error \\d+|Return value 3|error status' | Select-Object -Last 5 | ForEach-Object {{ $_.Line.Trim() }}) -join ' / ' }}",
        #{ "CW_LOG": Value::String(log) }
    )?
    let lines = detail.stdout.trim()
    let msg = "msiexec " + (if removing { "/x" } else { "/i" }) + " exited " + str(out.code) + " (log: " + log + ")"
    if lines != "" { return Err(msg + ": " + lines) }
    Err(msg)
}

fn install(params: Value, hit: List[string]) -> Result[ApplyResult, string] {
    let product_id = common::param_str(params, "product_id", "")
    let src = common::param_str(params, "path", "")
    if src == "" { return Err("missing 'path' parameter (the .msi to install)") }
    let local = common::local_file(src, common::param_str(params, "sha256", ""), "installer.msi")?
    let props = msi_properties(local)?
    let code = get_str(props, "ProductCode").to_upper()
    let pkg_version = get_str(props, "ProductVersion")
    let wanted: List[string] = []
    for id in ids(params) { wanted.push(id.to_upper()) }
    if !wanted.contains(code) {
        return Err("'" + src + "' has ProductCode " + code + ", not " + product_id +
            ". A major upgrade changes the ProductCode, so set product_id to the new package's code")
    }
    let want = common::param_str(params, "version", "")
    if want != "" && pkg_version != want {
        return Err("'" + src + "' is ProductVersion " + pkg_version + ", but version is " + want)
    }
    // The same ProductCode is already installed at another version: a minor
    // upgrade, which msiexec only performs when told to reinstall. The
    // transforms applied at first install are cached and reused, so none are
    // passed (msiexec rejects a changed transform list on reinstall).
    let argline = "/i \"" + local + "\" /qn /norestart"
    if !hit.is_empty() {
        argline = argline + " REINSTALL=ALL REINSTALLMODE=vomus"
    } else {
        let mst: List[string] = []
        let n = 0
        for t in common::param_list(params, "transforms") {
            mst.push(common::local_file(t, "", "transform-" + str(n) + ".mst")?)
            n = n + 1
        }
        if !mst.is_empty() { argline = argline + " TRANSFORMS=\"" + mst.join(";") + "\"" }
    }
    for p in common::param_list(params, "properties") { argline = argline + " " + p }
    let res = run_msiexec(argline, product_id, false)?
    if res == ApplyResult::RebootRequired { return Ok(res) }
    let after = found(params)?
    if after.is_empty() {
        return Err("msiexec succeeded but no Uninstall key exists for " + ids(params).join(" or ") + "; check product_id")
    }
    if want != "" {
        let have = display_version(after.get(0).unwrap_or(""))?
        if have != want { return Err("msiexec succeeded but DisplayVersion is " + have + ", not " + want) }
    }
    Ok(ApplyResult::Success)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let hit = found(params)?
    if common::want_present(params)? { return install(params, hit) }
    // Nothing registered: nothing to remove. Otherwise remove the GUID that
    // was actually found, which may be alt_product_id.
    if hit.is_empty() { return Ok(ApplyResult::Success) }
    let guid = hit.get(1).unwrap_or("")
    run_msiexec("/x " + guid + " /qn /norestart", guid, true)
}
