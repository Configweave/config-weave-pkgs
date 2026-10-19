use value
use json
use fs
use path
use http
use archive
use log
use sys
use shell
use common

// The shim is a one-line .cmd in System32, which is on every account's
// PATH, so SYSTEM and accounts that never logged on can run `winget`. Its
// first line marks it as this resource's own: only a marked shim is ever
// rewritten or deleted.
fn shim_path() -> string { "C:\\Windows\\System32\\winget.cmd" }
fn shim_marker() -> string { "config-weave windows_packages.winget_installed" }
fn shim_text(exe: string) -> string {
    "@rem " + shim_marker() + ": runs the newest App Installer winget for accounts without its App Execution Alias\r\n@\"" + exe + "\" %*\r\n"
}

fn validate(params: Value) -> Result[bool, string] {
    common::validate_version(common::param_str(params, "version", ""))?
    let m = common::param_str(params, "method", "auto")
    if !["auto", "release", "gallery"].contains(m) { return Err("invalid 'method' value '" + m + "' (expected :auto, :release or :gallery)") }
    common::want_present(params)
}

// What is on the machine now. Only WindowsApps is searched for winget.exe,
// never PATH: a shim on PATH must not count as an installed winget.
fn state() -> Result[Value, string] {
    let script = "$exe = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps\\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\\winget.exe') -ErrorAction SilentlyContinue | Sort-Object {{ [version]($_.Directory.Name -split '_')[1] }} | Select-Object -Last 1 -ExpandProperty FullName\n" +
        "$ver = ''; $code = 0\n" +
        "if ($exe) {{ try {{ $o = @(& $exe --version 2>&1); $code = $LASTEXITCODE }} catch {{ $code = -1 }}; if ($code -eq 0) {{ $ver = ([string]$o[0]).Trim() }} }}\n" +
        "$prov = @(Get-AppxProvisionedPackage -Online | Where-Object {{ $_.DisplayName -eq 'Microsoft.DesktopAppInstaller' }}).Count -gt 0\n" +
        "$pk = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)\n" +
        "$inst = $pk.Count -gt 0\n" +
        "$fixed = @($pk | Where-Object {{ $_.NonRemovable }}).Count -gt 0\n" +
        "$shim = Join-Path $env:SystemRoot 'System32\\winget.cmd'\n" +
        "$text = if (Test-Path -LiteralPath $shim) {{ [IO.File]::ReadAllText($shim) }} else {{ '' }}\n" +
        "$vc = (Test-Path (Join-Path $env:SystemRoot 'System32\\vcruntime140.dll')) -and (Test-Path (Join-Path $env:SystemRoot 'System32\\vcruntime140_1.dll')) -and (Test-Path (Join-Path $env:SystemRoot 'System32\\msvcp140.dll'))\n" +
        "$system = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem\n" +
        "$pwsh = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'PowerShell\\*\\pwsh.exe') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName | Sort-Object) | Select-Object -Last 1\n" +
        "ConvertTo-Json -Compress @{{ exe = [string]$exe; version = $ver; code = [int]$code; provisioned = $prov; installed = $inst; nonremovable = $fixed; shim = $text; vc = $vc; system = $system; pwsh = [string]$pwsh }}\n"
    let out = common::query(script, #{})?
    if !out.success { return Err(common::failure("reading the App Installer state", out)) }
    json::parse(out.stdout.trim())
}

// Windows Server 2025 and Windows 11 register App Installer as a
// NonRemovable system package: Remove-AppxPackage reports success and
// leaves it, and deprovisioning fails. ensure = :absent cannot be met there,
// so check and apply say so, before anything is changed.
fn non_removable(s: Value) -> Result[unit, string] {
    if common::get_bool(s, "nonremovable") { return Err("ensure = :absent cannot be met: App Installer is a non-removable system package on this Windows (Get-AppxPackage reports NonRemovable). Use system_shim = false to drop only the shim") }
    Ok(())
}

fn runs(s: Value) -> bool { common::get_str(s, "exe") != "" && common::get_str(s, "version") != "" }

fn version_low(params: Value, s: Value) -> bool {
    let want = common::param_str(params, "version", "")
    want != "" && !common::version_ok(common::get_str(s, "version"), want, true)
}

fn ours(text: string) -> bool { text.contains(shim_marker()) }

fn check(params: Value) -> Result[CheckResult, string] {
    let present = validate(params)?
    let s = state()?
    let shim = common::get_str(s, "shim")
    if !present {
        non_removable(s)?
        if common::get_bool(s, "provisioned") || common::get_bool(s, "installed") || ours(shim) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !runs(s) || version_low(params, s) { return Ok(CheckResult::NotConfigured) }
    if common::param_bool(params, "all_users", true) && !common::get_bool(s, "provisioned") { return Ok(CheckResult::NotConfigured) }
    if common::param_bool(params, "system_shim", true) {
        if shim != shim_text(common::get_str(s, "exe")) { return Ok(CheckResult::NotConfigured) }
    } else if ours(shim) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn arch() -> Result[string, string] {
    let a = sys::arch()
    if a == "x86_64" { return Ok("x64") }
    if a == "aarch64" { return Ok("arm64") }
    Err("App Installer is not published for the architecture '" + a + "'")
}

// The Visual C++ 2015-2022 runtime winget.exe links against. Run from
// WindowsApps outside its package (as SYSTEM always is), winget cannot use
// the VCLibs framework package and loads the machine-wide runtime instead.
// 1638 is "a newer version is already installed".
fn install_vc_runtime() -> Result[bool, string] {
    let work = fs::temp_dir()?
    let file = path::join(work, "vc_redist.exe")
    let url = "https://aka.ms/vs/17/release/vc_redist." + arch()? + ".exe"
    if let Err(e) = common::download(url, file, 0, "") {
        fs::delete_dir(work)?
        return Err(e)
    }
    let out = common::action("$p = Start-Process -FilePath $env:CW_FILE -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru\nexit $p.ExitCode\n", #{ "CW_FILE": Value::String(file) })
    fs::delete_dir(work)?
    let r = out?
    if r.code == 3010 || r.code == 1641 { return Ok(true) }
    if r.success || r.code == 1638 { return Ok(false) }
    Err(common::failure("installing the Visual C++ runtime from " + url, r))
}

fn asset(assets: List[Value], test: string) -> Option[Value] {
    for a in assets {
        let name = common::get_str(a, "name")
        if test == "bundle" && name.ends_with(".msixbundle") { return Some(a) }
        if test == "license" && name.ends_with("_License1.xml") { return Some(a) }
        if test == "deps" && name == "DesktopAppInstaller_Dependencies.zip" { return Some(a) }
    }
    None
}

// GitHub publishes each asset's sha256 as "sha256:<hex>".
fn fetch(a: Value, dir: string) -> Result[string, string] {
    let file = path::join(dir, common::get_str(a, "name"))
    let digest = common::get_str(a, "digest")
    let sha = if digest.starts_with("sha256:") { digest.slice(7, digest.len()) } else { "" }
    let size = if let Some(v) = a.get("size") { v.as_int().unwrap_or(0) } else { 0 }
    common::download(common::get_str(a, "browser_download_url"), file, size, sha)?
    Ok(file)
}

// The latest microsoft/winget-cli release: the App Installer msixbundle,
// its licence and the VCLibs / UI.Xaml dependency packages, provisioned
// with Add-AppxProvisionedPackage (every user, current and future) or added
// for the current account only.
fn provision_release(params: Value) -> Result[unit, string] {
    let url = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
    let resp = http::get(url, Value::Map(#{ "timeout": Value::Int(60), "headers": Value::Map(#{ "User-Agent": Value::String("config-weave"), "Accept": Value::String("application/vnd.github+json") }) }))
    if let Err(e) = resp { return Err("reading the latest winget release from " + url + " failed: " + e) }
    let r = resp?
    if r.status != 200 { return Err("reading the latest winget release from " + url + " failed: HTTP " + str(r.status)) }
    let rel = json::parse(r.body)?
    let tag = common::get_str(rel, "tag_name")
    let want = common::param_str(params, "version", "")
    if want != "" && !common::version_ok(tag, want, true) { return Err("the latest winget release is " + tag + ", older than the requested version " + want) }
    let assets: List[Value] = []
    if let Some(v) = rel.get("assets") { assets = v.as_list().unwrap_or([]) }
    let b = asset(assets, "bundle")
    let l = asset(assets, "license")
    let d = asset(assets, "deps")
    if b.is_none() || l.is_none() || d.is_none() { return Err("winget release " + tag + " lacks the msixbundle, licence or dependency assets") }
    log::info("provisioning App Installer from winget release " + tag)
    let work = fs::temp_dir()?
    let result = provision_from(params, work, b.unwrap(), l.unwrap(), d.unwrap())
    fs::delete_dir(work)?
    result
}

fn provision_from(params: Value, work: string, b: Value, l: Value, d: Value) -> Result[unit, string] {
    let bundle = fetch(b, work)?
    let license = fetch(l, work)?
    let deps = path::join(work, "deps")
    fs::mkdir(deps)?
    archive::extract_zip(fetch(d, work)?, deps)?
    let script = "$deps = @(Get-ChildItem -LiteralPath $env:CW_DEPS -Recurse -Include *.appx, *.msix | Where-Object {{ $_.FullName -match ('\\\\' + $env:CW_ARCH + '\\\\') }} | Select-Object -ExpandProperty FullName)\n" +
        "if ($deps.Count -eq 0) {{ [Console]::Error.WriteLine('the dependency archive holds no ' + $env:CW_ARCH + ' packages'); exit 1 }}\n" +
        "if ($env:CW_ALL -eq '1') {{\n" +
        "  $null = Add-AppxProvisionedPackage -Online -PackagePath $env:CW_BUNDLE -DependencyPackagePath $deps -LicensePath $env:CW_LICENSE\n" +
        "}} else {{\n" +
        "  Add-AppxPackage -Path $env:CW_BUNDLE -DependencyPath $deps -ForceApplicationShutdown\n" +
        "}}\n"
    let out = common::action(script, #{
        "CW_BUNDLE": Value::String(bundle),
        "CW_LICENSE": Value::String(license),
        "CW_DEPS": Value::String(deps),
        "CW_ARCH": Value::String(arch()?),
        "CW_ALL": Value::String(if common::param_bool(params, "all_users", true) { "1" } else { "0" })
    })?
    if !out.success { return Err(common::failure("provisioning App Installer", out)) }
    Ok(())
}

// Microsoft.WinGet.Client from the PowerShell Gallery, then
// Repair-WinGetPackageManager. The module is unpacked from its .nupkg
// rather than through Install-Module: the in-box PowerShellGet 1.0.0.1 gives
// up whenever the gallery's API root is slow to answer. The cmdlet runs only
// in PowerShell 7, and refuses -AllUsers as SYSTEM.
fn provision_gallery(params: Value, s: Value) -> Result[unit, string] {
    let pwsh = common::get_str(s, "pwsh")
    if pwsh == "" { return Err("method :gallery needs PowerShell 7: Repair-WinGetPackageManager does not run in Windows PowerShell") }
    let all = common::param_bool(params, "all_users", true)
    if all && common::get_bool(s, "system") { return Err("method :gallery cannot provision for all users as SYSTEM: Repair-WinGetPackageManager -AllUsers refuses the SYSTEM account. Use :release") }
    let work = fs::temp_dir()?
    let result = gallery_from(work, pwsh, all)
    fs::delete_dir(work)?
    result
}

fn gallery_from(work: string, pwsh: string, all: bool) -> Result[unit, string] {
    let nupkg = path::join(work, "client.zip")
    common::download("https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client", nupkg, 0, "")?
    let unpacked = path::join(work, "client")
    fs::mkdir(unpacked)?
    archive::extract_zip(nupkg, unpacked)?
    let script = "$ErrorActionPreference = 'Stop'\n" +
        "[xml]$spec = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $env:CW_DIR -Filter *.nuspec | Select-Object -First 1).FullName\n" +
        "$dest = Join-Path $env:ProgramFiles ('PowerShell\\Modules\\Microsoft.WinGet.Client\\' + $spec.package.metadata.version)\n" +
        "$null = New-Item -ItemType Directory -Path $dest -Force\n" +
        "Get-ChildItem -LiteralPath $env:CW_DIR | Where-Object {{ $_.Name -notin '_rels', 'package', '[Content_Types].xml' -and $_.Extension -ne '.nuspec' }} | Copy-Item -Destination $dest -Recurse -Force\n" +
        "Import-Module (Join-Path $dest 'Microsoft.WinGet.Client.psd1')\n" +
        "if ($env:CW_ALL -eq '1') {{ Repair-WinGetPackageManager -AllUsers -Latest -Force }} else {{ Repair-WinGetPackageManager -Latest -Force }}\n"
    let file = path::join(work, "repair.ps1")
    fs::write(file, "\u{FEFF}" + script)?
    let out = shell::run("\"" + pwsh + "\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\"", Value::Map(#{
        "timeout": Value::Int(3600),
        "env": Value::Map(#{ "CW_DIR": Value::String(unpacked), "CW_ALL": Value::String(if all { "1" } else { "0" }) })
    }))?
    if !out.success { return Err(common::failure("Repair-WinGetPackageManager", out)) }
    Ok(())
}

fn provision(params: Value, s: Value) -> Result[unit, string] {
    let m = common::param_str(params, "method", "auto")
    if m == "release" { return provision_release(params) }
    if m == "gallery" { return provision_gallery(params, s) }
    // :auto takes the gallery route only where it can work, and falls back
    // to the release when the gallery is unreachable or the repair fails.
    let can_gallery = common::get_str(s, "pwsh") != "" && !(common::param_bool(params, "all_users", true) && common::get_bool(s, "system"))
    if can_gallery {
        if let Err(e) = provision_gallery(params, s) {
            log::warn("Repair-WinGetPackageManager failed, provisioning from the winget release instead: " + e)
        } else {
            return Ok(())
        }
    }
    provision_release(params)
}

fn write_shim(params: Value, s: Value) -> Result[unit, string] {
    let text = common::get_str(s, "shim")
    if common::param_bool(params, "system_shim", true) {
        let want = shim_text(common::get_str(s, "exe"))
        if text == want { return Ok(()) }
        if text != "" && !ours(text) { return Err("'" + shim_path() + "' exists and was not written by this resource — refusing to replace it") }
        // Beside the target, then renamed over it, so a half-written shim
        // never runs.
        let tmp = shim_path() + ".config-weave-tmp"
        fs::write(tmp, want)?
        fs::move(tmp, shim_path())?
    } else if ours(text) {
        fs::delete(shim_path())?
    }
    Ok(())
}

// Per-user registrations go first: a package still registered for a user
// cannot be deprovisioned.
fn remove() -> Result[ApplyResult, string] {
    let s = state()?
    non_removable(s)?
    if ours(common::get_str(s, "shim")) { fs::delete(shim_path())? }
    let script = "foreach ($p in @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller)) {{ Remove-AppxPackage -Package $p.PackageFullName -AllUsers }}\n" +
        "foreach ($p in @(Get-AppxProvisionedPackage -Online | Where-Object {{ $_.DisplayName -eq 'Microsoft.DesktopAppInstaller' }})) {{ $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName }}\n"
    let out = common::action(script, #{})?
    if !out.success { return Err(common::failure("removing App Installer", out)) }
    Ok(ApplyResult::Success)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if !validate(params)? { return remove() }
    let reboot = false
    let s = state()?
    // The runtime first: an App Installer that is present but cannot start
    // needs only this, not a new package.
    if !common::get_bool(s, "vc") {
        reboot = install_vc_runtime()?
        s = state()?
    }
    let all = common::param_bool(params, "all_users", true)
    if !runs(s) || version_low(params, s) || (all && !common::get_bool(s, "provisioned")) {
        provision(params, s)?
        s = state()?
    }
    if common::get_str(s, "exe") == "" { return Err("App Installer was provisioned, but there is no winget.exe under " + "C:\\Program Files\\WindowsApps") }
    if !runs(s) { return Err("winget.exe at '" + common::get_str(s, "exe") + "' does not start (exit " + str(common::get_int(s, "code")) + ")") }
    if version_low(params, s) { return Err("winget is " + common::get_str(s, "version") + " after provisioning, older than the requested " + common::param_str(params, "version", "")) }
    write_shim(params, s)?
    if reboot { return Ok(ApplyResult::RebootRequired) }
    Ok(ApplyResult::Success)
}
