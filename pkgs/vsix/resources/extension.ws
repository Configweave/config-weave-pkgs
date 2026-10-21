use value
use http
use json
use env
use log
use common
use vs
use vscode
use parts
use vrange

fn host(params: Value) -> Result[string, string] {
    let h = common::param_str(params, "host", "visual_studio")
    if h == "visual_studio" || h == "vscode" { return Ok(h) }
    Err("invalid 'host' value '" + h + "' (expected :visual_studio or :vscode)")
}

fn scope(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "scope", "machine")
    if s == "machine" || s == "user" { return Ok(s) }
    Err("invalid 'scope' value '" + s + "' (expected :machine or :user)")
}

// Checked by check() and apply() alike.
fn validate(params: Value) -> Result[unit, string] {
    common::want_present(params)?
    let h = host(params)?
    scope(params)?
    let id = common::param_str(params, "id", "")
    if id == "" { return Err("missing 'id' parameter") }
    common::validate_token("id", id)?
    vrange::validate("version", common::param_str(params, "version", ""))?
    let source = common::param_str(params, "source", "")
    common::cmd_safe("source", source)?
    common::validate_sha256(common::param_str(params, "sha256", ""))?
    if common::is_marketplace_name(source) { common::validate_token("source", source)? }
    parts::validate(common::param_list(params, "remove_parts"))?
    if h == "visual_studio" {
        vs::version_range(common::param_str(params, "vs_version", ""))?
        vs::validate_products(common::param_str(params, "vs_products", "*"))?
        if common::param_str(params, "user", "") != "" || common::param_str(params, "code", "") != "" {
            return Err("'user' and 'code' apply to host = :vscode only")
        }
    } else {
        if !common::param_list(params, "remove_parts").is_empty() { return Err("'remove_parts' applies to host = :visual_studio only") }
        if scope(params)? != "machine" { return Err("'scope' applies to host = :visual_studio only; VS Code extensions are per user (see 'user')") }
        if common::param_str(params, "vs_version", "") != "" { return Err("'vs_version' applies to host = :visual_studio only") }
        // A VS Code extension id is publisher.name.
        if !id.contains(".") { return Err("a VS Code extension 'id' is publisher.name, got '" + id + "'") }
        if common::is_marketplace_name(source) && source.to_lower() != id.to_lower() {
            return Err("for VS Code a Marketplace 'source' must equal 'id' (or be left empty), got '" + source + "'")
        }
        let user = common::param_str(params, "user", "")
        common::single_line("user", user)?
        common::cmd_safe("code", common::param_str(params, "code", ""))?
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Visual Studio
// ---------------------------------------------------------------------

fn vs_instances(params: Value) -> Result[List[Value], string] {
    let range = vs::version_range(common::param_str(params, "vs_version", ""))?
    let products = common::param_str(params, "vs_products", "*")
    let found = vs::instances(products, range)?
    if found.is_empty() {
        return Err("no Visual Studio instance matches vs_version '" + common::param_str(params, "vs_version", "") + "' and vs_products '" + products + "' (Build Tools and the test agent take no extensions)")
    }
    Ok(found)
}

fn vs_ok(inst: Value, params: Value) -> Result[bool, string] {
    let found = vs::installed(inst, scope(params)?, common::param_str(params, "id", ""))?
    if !common::want_present(params)? { return Ok(found.is_empty()) }
    vs::has(found, common::param_str(params, "version", ""))
}

// The versions of a Marketplace item, newest first, from the gallery's
// extensionquery API: only the newest when `all` is false. VS Code
// pre-release versions (the Microsoft.VisualStudio.Code.PreRelease
// property) are left out of the full list, so a range never resolves to
// one; an item can list a version once per target platform.
fn marketplace_versions(item: string, all: bool) -> Result[List[string], string] {
    // filterType 7 is the item name; flags 1 = IncludeVersions, 16 =
    // IncludeVersionProperties, 512 = IncludeLatestVersionOnly.
    let criterion = Value::Map(#{ "filterType": Value::Int(7), "value": Value::String(item) })
    let filter = Value::Map(#{ "criteria": Value::List([criterion]) })
    let flags = if all { 17 } else { 513 }
    let body = json::to_string(Value::Map(#{ "filters": Value::List([filter]), "flags": Value::Int(flags) }))
    let res = http::post("https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery", body, Value::Map(#{
        "headers": Value::Map(#{
            "Content-Type": Value::String("application/json"),
            "Accept": Value::String("application/json;api-version=3.0-preview.1")
        }),
        "timeout": Value::Int(120)
    }))?
    if res.status != 200 { return Err("the Marketplace query for " + item + " answered HTTP " + str(res.status)) }
    let m = json::parse(res.body)?
    let found: List[string] = []
    for r in common::get_list(m, "results") {
        for e in common::get_list(r, "extensions") {
            for v in common::get_list(e, "versions") {
                let ver = common::get_str(v, "version")
                let pre = common::get_list(v, "properties").any(|p| common::get_str(p, "key") == "Microsoft.VisualStudio.Code.PreRelease" && common::get_str(p, "value").to_lower() == "true")
                if ver != "" && !pre && !found.contains(ver) { found.push(ver) }
            }
        }
    }
    if found.is_empty() { return Err("the Visual Studio Marketplace has no item named " + item) }
    Ok(found)
}

// The newest version of a Marketplace item.
fn latest_version(item: string) -> Result[string, string] {
    Ok(marketplace_versions(item, false)?.get(0).unwrap_or(""))
}

// The version of a Marketplace item to install for `version`: the newest
// when it is empty or *, an exact version (or a pin that is not range
// syntax) as written, and otherwise the newest the gallery lists that
// satisfies the range.
fn marketplace_version(item: string, version: string) -> Result[string, string] {
    if vrange::any(version) { return latest_version(item) }
    if vrange::exact(version) || vrange::opaque(version) { return Ok(version) }
    vrange::pick("extension " + item, marketplace_versions(item, true)?, version, "the Visual Studio Marketplace")
}

// The .vsix to install: a local path, a downloaded URL, or the Marketplace
// item's vspackage at `version` (the newest when version is empty).
fn vsix_file(params: Value) -> Result[string, string] {
    let source = common::param_str(params, "source", "")
    let sha = common::param_str(params, "sha256", "")
    if source == "" { return Err("'source' is required to install into Visual Studio: a .vsix path, an http(s) URL or a Marketplace item name (publisher.name)") }
    if common::is_marketplace_name(source) {
        let version = marketplace_version(source, common::param_str(params, "version", ""))?
        let pn = source.split(".")
        let publisher = pn.get(0).unwrap_or("")
        let name = source.slice(publisher.len() + 1, source.len())
        let url = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/" + publisher + "/vsextensions/" + name + "/" + version + "/vspackage"
        return common::fetch(url, sha, source + "-" + version + ".vsix")
    }
    if common::is_url(source) { return common::fetch(source, sha, "extension.vsix") }
    common::local_source(source, sha)
}

// The package must be the extension the step names, so check and apply
// agree after the install.
fn check_identity(file: string, params: Value, vscode_host: bool) -> Result[unit, string] {
    let idv = common::vsix_identity(file)?
    let id = common::param_str(params, "id", "")
    let have = if vscode_host { idv.get(2).unwrap_or("") + "." + idv.get(0).unwrap_or("") } else { idv.get(0).unwrap_or("") }
    if have.to_lower() != id.to_lower() { return Err(file + " is extension '" + have + "', not id '" + id + "'") }
    let version = common::param_str(params, "version", "")
    let hv = idv.get(1).unwrap_or("")
    // The package is what gets installed, whatever the range, so one outside
    // it is refused before the installer runs.
    if !vrange::any(version) && !common::same_version(hv, version) && !vrange::satisfies("extension " + id, hv, version, "the manifest of " + file)? {
        return Err(file + " is version " + hv + ", which does not satisfy version '" + version + "'")
    }
    Ok(())
}

fn vs_apply(params: Value) -> Result[ApplyResult, string] {
    let insts = vs_instances(params)?
    let sc = scope(params)?
    let id = common::param_str(params, "id", "")
    if sc == "machine" && !env::is_elevated() { return Err("scope = :machine (VSIXInstaller /admin) needs an elevated run") }
    if !common::want_present(params)? {
        for inst in insts {
            if !vs_ok(inst, params)? { vs::uninstall(inst, sc, id)? }
        }
        return Ok(ApplyResult::Success)
    }
    let todo = insts.filter(|i| !vs_ok(i, params).unwrap_or(false))
    if todo.is_empty() { return Ok(ApplyResult::Success) }
    let file = vsix_file(params)?
    check_identity(file, params, false)?
    let strip = common::param_list(params, "remove_parts")
    if !strip.is_empty() { file = parts::strip(file, strip)? }
    for inst in todo {
        vs::install(inst, sc, file)?
        if !vs_ok(inst, params)? {
            return Err("VSIXInstaller succeeded, but no extension.vsixmanifest with Id " + id + (if common::param_str(params, "version", "") != "" { " and Version " + common::param_str(params, "version", "") } else { "" }) + " is under " + vs::roots(inst, sc).join(" or "))
        }
    }
    Ok(ApplyResult::Success)
}

// ---------------------------------------------------------------------
// VS Code
// ---------------------------------------------------------------------

fn code_target(params: Value) -> Result[Option[Value], string] {
    vscode::target(common::param_str(params, "user", ""), common::param_str(params, "code", ""))
}

fn code_ok(t: Value, params: Value) -> Result[bool, string] {
    vscode::is_configured(t, common::param_str(params, "id", ""), common::param_str(params, "version", ""), common::want_present(params)?)
}

fn code_apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    let found = code_target(params)?
    if found.is_none() {
        if !present { return Ok(ApplyResult::Success) }
        return Err("no VS Code CLI (code.cmd, code-insiders.cmd or codium.cmd) was found; set 'code'")
    }
    let t = found.unwrap()
    let id = common::param_str(params, "id", "")
    if code_ok(t, params)? { return Ok(ApplyResult::Success) }
    if !present {
        vscode::uninstall(t, id)?
    } else {
        let source = common::param_str(params, "source", "")
        let version = common::param_str(params, "version", "")
        let what = id
        let from_marketplace = true
        if source != "" && !common::is_marketplace_name(source) {
            from_marketplace = false
            what = if common::is_url(source) { common::fetch(source, common::param_str(params, "sha256", ""), id + ".vsix")? } else { common::local_source(source, common::param_str(params, "sha256", ""))? }
            check_identity(what, params, true)?
        } else if !vrange::any(version) {
            what = id + "@" + marketplace_version(id, version)?
        }
        vscode::install(t, what, from_marketplace)?
    }
    if !code_ok(t, params)? {
        return Err("the VS Code CLI succeeded, but " + id + " is still " + (if present { "not installed" + (if common::param_str(params, "version", "") != "" { " at version " + common::param_str(params, "version", "") } else { "" }) } else { "installed" }))
    }
    Ok(ApplyResult::Success)
}

// ---------------------------------------------------------------------

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    if host(params)? == "visual_studio" {
        for inst in vs_instances(params)? {
            if !vs_ok(inst, params)? { return Ok(CheckResult::NotConfigured) }
        }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let found = code_target(params)?
    if found.is_none() {
        if !common::want_present(params)? { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if code_ok(found.unwrap(), params)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    if host(params)? == "visual_studio" { return vs_apply(params) }
    code_apply(params)
}
