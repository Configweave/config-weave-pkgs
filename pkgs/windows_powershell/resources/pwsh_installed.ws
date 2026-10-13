use value
use fs
use path
use shell
use sys
use http
use hash
use archive
use log
use common

// Every external command carries a timeout. A resource that can hang forever
// is a defect: the timeout kills the child and surfaces an Err, which the
// engine reports as a failed step naming this resource.
fn opts(seconds: int) -> Value { Value::Map(#{ "timeout": Value::Int(seconds) }) }

fn preview(params: Value) -> bool { common::param_str(params, "channel", "stable") == "preview" }

// Validated once: the version reaches download URLs, package specs and
// command lines.
fn version(params: Value) -> Result[string, string] {
    let v = common::param_str(params, "version", "")
    common::version_chars("version", v)?
    Ok(v)
}

fn major(params: Value) -> Result[string, string] {
    let v = version(params)?
    if v == "" { return Ok("7") }
    Ok(v.split(".")[0])
}

// :auto is the documented recommendation per platform: the MSI on Windows
// (the enterprise-deployment package) and the distro package on Linux.
fn method(params: Value) -> Result[string, string] {
    let requested = common::param_str(params, "method", "auto")
    let windows = sys::family() == "windows"
    let resolved = if requested != "auto" { requested } else if windows { "msi" } else { "repo" }
    let for_windows = ["winget", "msi", "zip"]
    let for_linux = ["repo", "tarball"]
    if windows && !for_windows.contains(resolved) {
        return Err("method :" + resolved + " is a Linux method; use :winget, :msi or :zip on Windows")
    }
    if !windows && !for_linux.contains(resolved) {
        return Err("method :" + resolved + " is a Windows method; use :repo or :tarball on Linux")
    }
    Ok(resolved)
}

// The root the MSI (and winget, which runs the MSI) installs into and owns.
fn msi_root(params: Value) -> Result[string, string] {
    let suffix = if preview(params) { major(params)? + "-preview" } else { major(params)? }
    Ok("C:\\Program Files\\PowerShell\\" + suffix)
}

// The archive methods default to a root named for the full version, so they
// never land on the tree the MSI or the distro package owns
// (.../PowerShell/7, /opt/microsoft/powershell/7) — which is also what lets
// several versions sit side by side.
fn install_root(params: Value) -> Result[string, string] {
    let explicit = common::param_str(params, "install_root", "")
    if explicit != "" { return Ok(explicit) }
    let v = version(params)?
    if v == "" { return Err("'install_root' is required when 'version' is empty — there is no default root to derive without a version") }
    if sys::family() == "windows" { return Ok("C:\\Program Files\\PowerShell\\" + v) }
    Ok("/opt/microsoft/powershell/" + v)
}

fn binary_name() -> string {
    if sys::family() == "windows" { return "pwsh.exe" }
    "pwsh"
}

// The binary an install produces: inside the rooted install, inside the MSI's
// root, or the distro package's on PATH.
fn target_binary(params: Value, how: string) -> Result[string, string] {
    if how == "zip" || how == "tarball" { return Ok(path::join(install_root(params)?, binary_name())) }
    if sys::family() == "windows" { return Ok(path::join(msi_root(params)?, "pwsh.exe")) }
    if preview(params) { return Ok("pwsh-preview") }
    Ok("pwsh")
}

// "" when the binary is missing or will not run — never an error, because
// run 1 checks every step before the install step has had its chance.
fn installed_version(binary: string) -> Result[string, string] {
    if !common::on_path(binary) { return Ok("") }
    let out = shell::run(common::dq(binary) + " -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", opts(120))
    if let Ok(result) = out {
        if result.success { return Ok(result.stdout.trim()) }
    }
    Ok("")
}

fn arch_tag() -> Result[string, string] {
    let arch = sys::arch()
    if arch == "x86_64" { return Ok("x64") }
    if arch == "aarch64" { return Ok("arm64") }
    Err("no PowerShell release artefact is published for the architecture '" + arch + "'")
}

fn artefact_url(params: Value, how: string) -> Result[string, string] {
    let explicit = common::param_str(params, "url", "")
    if explicit != "" { return Ok(explicit) }
    let v = version(params)?
    if v == "" { return Err("'version' or 'url' is required for the :" + how + " method — there is no way to resolve the latest release offline") }
    let base = "https://github.com/PowerShell/PowerShell/releases/download/v" + v + "/PowerShell-" + v + "-"
    let arch = arch_tag()?
    if how == "msi" { return Ok(base + "win-" + arch + ".msi") }
    if how == "zip" { return Ok(base + "win-" + arch + ".zip") }
    Ok(base + "linux-" + arch + ".tar.gz")
}

fn verify_hash(params: Value, file: string) -> Result[unit, string] {
    let expected = common::param_str(params, "sha256", "")
    if expected == "" { return Ok(()) }
    let actual = hash::sha256_file(file)?
    if actual != expected.trim().to_lower() {
        return Err("sha256 mismatch for '" + file + "': expected " + expected + ", got " + actual)
    }
    Ok(())
}

fn download(params: Value, how: string, file: string) -> Result[unit, string] {
    let url = artefact_url(params, how)?
    log::info("downloading " + url)
    http::download(url, file, Value::Null)?
    verify_hash(params, file)
}

fn msi_properties(params: Value) -> string {
    let flag = ""
    if common::param_bool(params, "add_path", true) { flag = flag + " ADD_PATH=1" } else { flag = flag + " ADD_PATH=0" }
    if common::param_bool(params, "enable_remoting", false) { flag = flag + " ENABLE_PSREMOTING=1" }
    if common::param_bool(params, "register_manifest", true) { flag = flag + " REGISTER_MANIFEST=1" }
    if common::param_bool(params, "explorer_context_menu", false) { flag = flag + " ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1" }
    if common::param_bool(params, "file_context_menu", false) { flag = flag + " ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1" }
    if common::param_bool(params, "microsoft_update", false) { flag = flag + " USE_MU=1 ENABLE_MU=1" }
    flag
}

fn install_msi(params: Value) -> Result[ApplyResult, string] {
    let work = fs::temp_dir()?
    let file = path::join(work, "PowerShell.msi")
    if let Err(e) = download(params, "msi", file) {
        fs::delete_dir(work)?
        return Err(e)
    }
    let out = shell::run_streaming("msiexec.exe /package " + common::dq(file) + " /quiet /norestart" + msi_properties(params), opts(2400))
    fs::delete_dir(work)?
    let result = out?
    // 3010 and 1641 are "installed, but a reboot is needed".
    if result.code == 3010 || result.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !result.success { return Err(common::failure("msiexec", result)) }
    Ok(ApplyResult::Success)
}

// Uninstalls by product code, found through the Uninstall registry key rather
// than Win32_Product (whose every query triggers a consistency check and
// self-repair of every installed MSI). Only the requested channel goes:
// stable and preview are separate products ("PowerShell 7-x64",
// "PowerShell 7-preview-x64").
fn uninstall_msi(params: Value) -> Result[ApplyResult, string] {
    let want_preview = if preview(params) { "$true" } else { "$false" }
    let script = "$preview = " + want_preview + "\n$found = @(Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' -ErrorAction SilentlyContinue | Where-Object {{ [string]$_.DisplayName -like 'PowerShell 7*' -and $_.PSChildName -like '{{*}}' -and (([string]$_.DisplayName -like '*preview*') -eq $preview) }})\n$reboot = $false\nforeach ($p in $found) {{\n  $r = Start-Process msiexec.exe -ArgumentList '/x', $p.PSChildName, '/quiet', '/norestart' -Wait -PassThru\n  if ($r.ExitCode -eq 3010 -or $r.ExitCode -eq 1641) {{ $reboot = $true }}\n  elseif ($r.ExitCode -ne 0) {{ [Console]::Error.WriteLine('msiexec /x ' + $p.PSChildName + ' (' + $p.DisplayName + ') exited ' + $r.ExitCode); exit $r.ExitCode }}\n}}\nif ($reboot) {{ exit 3010 }}"
    let result = common::run_ps_streaming("windows_powershell", script, 2400)?
    if result.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !result.success { return Err(common::failure("uninstalling PowerShell", result)) }
    Ok(ApplyResult::Success)
}

fn winget_id(params: Value) -> string {
    if preview(params) { return "Microsoft.PowerShell.Preview" }
    "Microsoft.PowerShell"
}

fn install_winget(params: Value) -> Result[ApplyResult, string] {
    let v = version(params)?
    let pin = if v == "" { "" } else { " --version " + common::dq(v) }
    let cmd = "winget install --id " + winget_id(params) + " --source winget --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity" + pin
    let out = shell::run_streaming(cmd, opts(2400))?
    if !out.success { return Err(common::failure("winget install", out)) }
    Ok(ApplyResult::Success)
}

fn uninstall_winget(params: Value) -> Result[ApplyResult, string] {
    let out = shell::run_streaming("winget uninstall --id " + winget_id(params) + " --exact --silent --disable-interactivity", opts(2400))?
    if !out.success { return Err(common::failure("winget uninstall", out)) }
    Ok(ApplyResult::Success)
}

// A root this resource extracted carries this marker.
fn marker(root: string) -> string { path::join(root, ".config-weave-archive") }

// Whether a package manager owns `root`: dpkg or rpm on Linux, and on Windows
// the MSI's own root (.../PowerShell/<major> or <major>-preview) when this
// resource did not extract it.
fn package_owned(root: string) -> Result[bool, string] {
    if fs::is_file(marker(root)) { return Ok(false) }
    if sys::family() == "windows" {
        let leaf = path::filename(path::normalize(root)).to_lower().replace("-preview", "")
        let parent = path::parent(path::normalize(root)).to_lower().replace("/", "\\")
        return Ok(parent.ends_with("\\program files\\powershell") && leaf.parse_int().is_some())
    }
    let probe = shell::bash("if command -v dpkg >/dev/null 2>&1 && dpkg -S " + common::q(root) + " >/dev/null 2>&1; then exit 0; fi; if command -v rpm >/dev/null 2>&1 && rpm -qf " + common::q(root) + " >/dev/null 2>&1; then exit 0; fi; exit 1", opts(60))?
    Ok(probe.success)
}

// A root that already exists may be replaced or removed only when it is one
// this resource made (the marker) or an unmarked tarball/zip install from an
// older release (a pwsh binary, no package owner). Anything else is refused.
fn may_own(root: string) -> Result[unit, string] {
    if !fs::is_dir(root) { return Ok(()) }
    if fs::is_file(marker(root)) { return Ok(()) }
    if package_owned(root)? {
        return Err("'" + root + "' belongs to the installed PowerShell package — the archive methods will not overwrite or delete it. Set install_root to a directory of its own")
    }
    if fs::list_dir(root)?.is_empty() { return Ok(()) }
    if fs::is_file(path::join(root, binary_name())) { return Ok(()) }
    Err("'" + root + "' exists and is not a PowerShell this resource extracted — refusing to replace or delete it")
}

fn install_archive(params: Value, how: string) -> Result[ApplyResult, string] {
    let root = install_root(params)?
    may_own(root)?
    let work = fs::temp_dir()?
    let file = path::join(work, if how == "zip" { "PowerShell.zip" } else { "PowerShell.tar.gz" })
    if let Err(e) = download(params, how, file) {
        fs::delete_dir(work)?
        return Err(e)
    }
    if fs::is_dir(root) { fs::delete_dir(root)? }
    fs::mkdir(root)?
    let extracted = if how == "zip" { archive::extract_zip(file, root) } else { archive::extract_tar_gz(file, root) }
    fs::delete_dir(work)?
    extracted?
    fs::write(marker(root), "extracted by config-weave windows_powershell.pwsh_installed\n")?

    let binary = path::join(root, binary_name())
    if !fs::exists(binary) { return Err("the archive did not contain " + binary_name() + " at the root of '" + root + "'") }
    if sys::family() != "windows" {
        // The tarball preserves no execute bit through every extractor.
        let chmod = shell::bash("chmod +x " + common::q(binary), opts(60))?
        if !chmod.success { return Err(common::failure("chmod +x " + binary, chmod)) }
    }
    let link = common::param_str(params, "symlink", "")
    if link != "" {
        if fs::exists(link) || fs::read_link(link).is_ok() { fs::delete(link)? }
        let parent = path::parent(link)
        if parent != "" { fs::mkdir(parent)? }
        fs::symlink(binary, link)?
    }
    Ok(ApplyResult::Success)
}

fn uninstall_archive(params: Value) -> Result[ApplyResult, string] {
    let root = install_root(params)?
    may_own(root)?
    if fs::is_dir(root) { fs::delete_dir(root)? }
    let link = common::param_str(params, "symlink", "")
    // Only a link that points into this root is ours to remove.
    if link != "" {
        if let Ok(target) = fs::read_link(link) {
            if target.starts_with(root) { fs::delete(link)? }
        }
    }
    Ok(ApplyResult::Success)
}

fn package_name(params: Value) -> string {
    if preview(params) { return "powershell-preview" }
    "powershell"
}

// The package spec for a pinned version. packages.microsoft.com versions the
// deb as <version>-1.deb, with a prerelease's '-' written '~' (7.6.0~preview.5)
// so it sorts before the release; the rpm writes it '_'.
fn apt_spec(params: Value) -> Result[string, string] {
    let v = version(params)?
    if v == "" { return Ok(package_name(params)) }
    Ok(package_name(params) + "=" + v.replace("-", "~") + "-1.deb")
}

fn dnf_spec(params: Value) -> Result[string, string] {
    let v = version(params)?
    if v == "" { return Ok(package_name(params)) }
    Ok(package_name(params) + "-" + v.replace("-", "_"))
}

// Registering packages.microsoft.com and installing the distro package. The
// repository registration is the documented prerequisite, and is idempotent
// in its own right.
fn install_repo(params: Value) -> Result[ApplyResult, string] {
    let apt = common::q(apt_spec(params)?)
    let dnf = common::q(dnf_spec(params)?)
    // The repository is registered from the published prod.list plus the
    // signing key it names, rather than the packages-microsoft-prod.deb
    // convenience wrapper: installing that wrapper needs dpkg-deb, and so
    // needs a working repository before there is one. A pinned version may be
    // older than the one installed, hence --allow-downgrades.
    let script = "set -e\n. /etc/os-release\nif command -v apt-get >/dev/null 2>&1; then\n  install -d /usr/share/keyrings\n  if [ ! -f /usr/share/keyrings/microsoft-prod.gpg ]; then\n    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg\n  fi\n  curl -fsSL -o /etc/apt/sources.list.d/microsoft-prod.list \"https://packages.microsoft.com/config/$ID/$VERSION_ID/prod.list\"\n  apt-get update -qq\n  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-downgrades " + apt + "\nelif command -v dnf >/dev/null 2>&1; then\n  rpm --import https://packages.microsoft.com/keys/microsoft.asc\n  curl -fsSL -o /etc/yum.repos.d/microsoft-prod.repo \"https://packages.microsoft.com/config/$ID/$VERSION_ID/prod.repo\" || curl -fsSL -o /etc/yum.repos.d/microsoft-prod.repo https://packages.microsoft.com/config/rhel/9/prod.repo\n  dnf install -y " + dnf + "\nelse\n  echo 'no supported package manager (apt-get or dnf) found' >&2\n  exit 1\nfi"
    let result = shell::bash(script, opts(2400))?
    if !result.success { return Err(common::failure("installing the " + package_name(params) + " package", result)) }
    Ok(ApplyResult::Success)
}

fn uninstall_repo(params: Value) -> Result[ApplyResult, string] {
    let package = common::q(package_name(params))
    let script = "set -e\nif command -v apt-get >/dev/null 2>&1; then\n  DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq " + package + "\nelif command -v dnf >/dev/null 2>&1; then\n  dnf remove -y " + package + "\nfi"
    let out = shell::bash(script, opts(1200))?
    if !out.success { return Err(common::failure("removing the " + package_name(params) + " package", out)) }
    Ok(ApplyResult::Success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let how = method(params)?
    let current = installed_version(target_binary(params, how)?)?
    if !common::want_present(params)? {
        if current == "" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if current == "" { return Ok(CheckResult::NotConfigured) }
    let wanted = version(params)?
    // An empty version means "any build of this channel", which is the only
    // honest reading offline: resolving "latest" needs the network.
    if wanted == "" { return Ok(CheckResult::AlreadyConfigured) }
    if current == wanted { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let how = method(params)?
    let present = common::want_present(params)?
    if how == "msi" { return if present { install_msi(params) } else { uninstall_msi(params) } }
    if how == "winget" { return if present { install_winget(params) } else { uninstall_winget(params) } }
    if how == "zip" || how == "tarball" { return if present { install_archive(params, how) } else { uninstall_archive(params) } }
    if present { return install_repo(params) }
    uninstall_repo(params)
}
