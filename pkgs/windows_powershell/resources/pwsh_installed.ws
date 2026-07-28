use value
use fs
use path
use shell
use sys
use http
use hash
use archive
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// Every external command carries a timeout. A resource that can hang forever
// is a defect: the timeout kills the child and surfaces an Err, which the
// engine reports as a failed step naming this resource.
fn ps_opts(seconds: int) -> Value { Value::Map(#{ "timeout": Value::Int(seconds) }) }

fn dq(s: string) -> string { "\"" + s + "\"" }

fn preview(params: Value) -> bool { param_str(params, "channel", "stable") == "preview" }

// :auto is the documented recommendation per platform: the MSI on Windows
// (the enterprise-deployment package) and the distro package on Linux.
fn method(params: Value) -> Result[string, string] {
    let requested = param_str(params, "method", "auto")
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

// The directory a :zip / :tarball install owns. Defaulting it to the platform
// $PSHOME keeps the side-by-side case explicit: a caller who wants two
// versions gives each its own install_root.
fn install_root(params: Value) -> Result[string, string] {
    let explicit = param_str(params, "install_root", "")
    if explicit != "" { return Ok(explicit) }
    let version = param_str(params, "version", "")
    if version == "" { return Err("'install_root' is required when 'version' is empty — there is no default root to derive without a version") }
    let major = version.split(".")[0]
    let suffix = if preview(params) { major + "-preview" } else { major }
    if sys::family() == "windows" { return Ok("C:\\Program Files\\PowerShell\\" + suffix) }
    Ok("/opt/microsoft/powershell/" + suffix)
}

fn binary_name() -> string {
    if sys::family() == "windows" { return "pwsh.exe" }
    "pwsh"
}

// The binary a rooted install produces, or the one on PATH for the package
// methods that do not have a root of their own.
fn target_binary(params: Value, how: string) -> Result[string, string] {
    if how == "zip" || how == "tarball" { return Ok(path::join(install_root(params)?, binary_name())) }
    if sys::family() == "windows" {
        let version = param_str(params, "version", "")
        if version != "" {
            let major = version.split(".")[0]
            let suffix = if preview(params) { major + "-preview" } else { major }
            let candidate = "C:\\Program Files\\PowerShell\\" + suffix + "\\pwsh.exe"
            if fs::exists(candidate) { return Ok(candidate) }
        }
        return Ok("pwsh")
    }
    if preview(params) { return Ok("pwsh-preview") }
    Ok("pwsh")
}

// "" when the binary is missing or will not run — never an error, because
// run 1 checks every step before the install step has had its chance.
fn installed_version(binary: string) -> Result[string, string] {
    if binary.contains("/") || binary.contains("\\") {
        if !fs::exists(binary) { return Ok("") }
    }
    let out = shell::run(dq(binary) + " -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", ps_opts(120))
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
    let explicit = param_str(params, "url", "")
    if explicit != "" { return Ok(explicit) }
    let version = param_str(params, "version", "")
    if version == "" { return Err("'version' or 'url' is required for the :" + how + " method — there is no way to resolve the latest release offline") }
    let base = "https://github.com/PowerShell/PowerShell/releases/download/v" + version + "/PowerShell-" + version + "-"
    let arch = arch_tag()?
    if how == "msi" { return Ok(base + "win-" + arch + ".msi") }
    if how == "zip" { return Ok(base + "win-" + arch + ".zip") }
    Ok(base + "linux-" + arch + ".tar.gz")
}

fn verify_hash(params: Value, file: string) -> Result[unit, string] {
    let expected = param_str(params, "sha256", "")
    if expected == "" { return Ok(()) }
    let actual = hash::sha256_file(file)?
    if actual != expected.trim().to_lower() {
        return Err("sha256 mismatch for '" + file + "': expected " + expected + ", got " + actual)
    }
    Ok(())
}

fn msi_properties(params: Value) -> string {
    let flag = ""
    if param_bool(params, "add_path", true) { flag = flag + " ADD_PATH=1" } else { flag = flag + " ADD_PATH=0" }
    if param_bool(params, "enable_remoting", false) { flag = flag + " ENABLE_PSREMOTING=1" }
    if param_bool(params, "register_manifest", true) { flag = flag + " REGISTER_MANIFEST=1" }
    if param_bool(params, "explorer_context_menu", false) { flag = flag + " ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1" }
    if param_bool(params, "file_context_menu", false) { flag = flag + " ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1" }
    if param_bool(params, "microsoft_update", false) { flag = flag + " USE_MU=1 ENABLE_MU=1" }
    flag
}

fn install_msi(params: Value) -> Result[ApplyResult, string] {
    let work = fs::temp_dir()?
    let file = path::join(work, "PowerShell.msi")
    let url = artefact_url(params, "msi")?
    log::info("downloading " + url)
    let downloaded = http::download(url, file, Value::Null)
    if let Err(e) = downloaded {
        fs::delete_dir(work)?
        return Err(e)
    }
    if let Err(e) = verify_hash(params, file) {
        fs::delete_dir(work)?
        return Err(e)
    }
    let out = shell::run_streaming("msiexec.exe /package " + dq(file) + " /quiet /norestart" + msi_properties(params), ps_opts(2400))
    fs::delete_dir(work)?
    let result = out?
    // 3010 and 1641 are "installed, but a reboot is needed".
    if result.code == 3010 || result.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !result.success { return Err("msiexec failed (exit " + str(result.code) + "): " + result.stdout.trim() + " " + result.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn uninstall_msi(params: Value) -> Result[ApplyResult, string] {
    // Uninstalling by name rather than ProductCode: the code changes with
    // every release, and the display name is stable.
    let script = "$p = Get-CimInstance -ClassName Win32_Product -Filter \"Name LIKE 'PowerShell 7%'\"\nif ($null -eq $p) {{ exit 0 }}\nforeach ($i in $p) {{ $r = Start-Process msiexec.exe -ArgumentList ('/x', $i.IdentifyingNumber, '/quiet', '/norestart') -Wait -PassThru; if ($r.ExitCode -ne 0 -and $r.ExitCode -ne 3010) {{ exit $r.ExitCode }} }}\nexit 0"
    let work = fs::temp_dir()?
    let file = path::join(work, "uninstall.ps1")
    fs::write(file, script)?
    let out = shell::run_streaming("powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + dq(file), ps_opts(2400))
    fs::delete_dir(work)?
    let result = out?
    if !result.success { return Err("uninstalling PowerShell failed: " + result.stdout.trim() + " " + result.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn install_winget(params: Value) -> Result[ApplyResult, string] {
    let id = if preview(params) { "Microsoft.PowerShell.Preview" } else { "Microsoft.PowerShell" }
    let version = param_str(params, "version", "")
    let pin = if version == "" { "" } else { " --version " + version }
    let cmd = "winget install --id " + id + " --source winget --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity" + pin
    let out = shell::run_streaming(cmd, ps_opts(2400))?
    if !out.success { return Err("winget install failed: " + out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn uninstall_winget(params: Value) -> Result[ApplyResult, string] {
    let id = if preview(params) { "Microsoft.PowerShell.Preview" } else { "Microsoft.PowerShell" }
    let out = shell::run_streaming("winget uninstall --id " + id + " --exact --silent --disable-interactivity", ps_opts(2400))?
    if !out.success { return Err("winget uninstall failed: " + out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

// The archive methods own their root outright, which is what makes them the
// only side-by-side-capable ones.
fn install_archive(params: Value, how: string) -> Result[ApplyResult, string] {
    let root = install_root(params)?
    let work = fs::temp_dir()?
    let name = if how == "zip" { "PowerShell.zip" } else { "PowerShell.tar.gz" }
    let file = path::join(work, name)
    let url = artefact_url(params, how)?
    log::info("downloading " + url)
    let downloaded = http::download(url, file, Value::Null)
    if let Err(e) = downloaded {
        fs::delete_dir(work)?
        return Err(e)
    }
    if let Err(e) = verify_hash(params, file) {
        fs::delete_dir(work)?
        return Err(e)
    }
    if fs::is_dir(root) { fs::delete_dir(root)? }
    fs::mkdir(root)?
    let extracted = if how == "zip" { archive::extract_zip(file, root) } else { archive::extract_tar_gz(file, root) }
    fs::delete_dir(work)?
    extracted?

    let binary = path::join(root, binary_name())
    if !fs::exists(binary) { return Err("the archive did not contain " + binary_name() + " at the root of '" + root + "'") }
    if sys::family() != "windows" {
        // The tarball preserves no execute bit through every extractor.
        let chmod = shell::run("chmod +x " + dq(binary), ps_opts(60))?
        if !chmod.success { return Err("chmod +x " + binary + " failed: " + chmod.stderr.trim()) }
    }
    let link = param_str(params, "symlink", "")
    if link != "" {
        if fs::exists(link) { fs::delete(link)? }
        let parent = path::parent(link)
        if parent != "" { fs::mkdir(parent)? }
        fs::symlink(binary, link)?
    }
    Ok(ApplyResult::Success)
}

fn uninstall_archive(params: Value) -> Result[ApplyResult, string] {
    let root = install_root(params)?
    if fs::is_dir(root) { fs::delete_dir(root)? }
    let link = param_str(params, "symlink", "")
    if link != "" && fs::exists(link) { fs::delete(link)? }
    Ok(ApplyResult::Success)
}

fn package_name(params: Value) -> string {
    if preview(params) { return "powershell-preview" }
    "powershell"
}

// Registering packages.microsoft.com and installing the distro package. The
// repository registration is the documented prerequisite, and is idempotent
// in its own right.
fn install_repo(params: Value) -> Result[ApplyResult, string] {
    let package = package_name(params)
    // The repository is registered from the published prod.list plus the
    // signing key it names, rather than the packages-microsoft-prod.deb
    // convenience wrapper: installing that wrapper needs dpkg-deb, and so
    // needs a working repository before there is one.
    let script = "set -e\n. /etc/os-release\nif command -v apt-get >/dev/null 2>&1; then\n  install -d /usr/share/keyrings\n  if [ ! -f /usr/share/keyrings/microsoft-prod.gpg ]; then\n    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg\n  fi\n  curl -fsSL -o /etc/apt/sources.list.d/microsoft-prod.list \"https://packages.microsoft.com/config/$ID/$VERSION_ID/prod.list\"\n  apt-get update -qq\n  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq " + package + "\nelif command -v dnf >/dev/null 2>&1; then\n  rpm --import https://packages.microsoft.com/keys/microsoft.asc\n  curl -fsSL -o /etc/yum.repos.d/microsoft-prod.repo \"https://packages.microsoft.com/config/$ID/$VERSION_ID/prod.repo\" || curl -fsSL -o /etc/yum.repos.d/microsoft-prod.repo https://packages.microsoft.com/config/rhel/9/prod.repo\n  dnf install -y " + package + "\nelse\n  echo 'no supported package manager (apt-get or dnf) found' >&2\n  exit 1\nfi"
    // shell::bash rather than run_streaming: this needs real shell features
    // (command -v, sourcing /etc/os-release, a heredoc-free if/elif chain),
    // and run_streaming executes a program directly with no shell.
    let result = shell::bash(script, ps_opts(2400))?
    if !result.success { return Err("installing the " + package + " package failed: " + result.stdout.trim() + " " + result.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn uninstall_repo(params: Value) -> Result[ApplyResult, string] {
    let package = package_name(params)
    let script = "set -e\nif command -v apt-get >/dev/null 2>&1; then\n  DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq " + package + "\nelif command -v dnf >/dev/null 2>&1; then\n  dnf remove -y " + package + "\nfi"
    let out = shell::bash(script, ps_opts(1200))?
    if !out.success { return Err("removing the " + package + " package failed: " + out.stdout.trim() + " " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let how = method(params)?
    let current = installed_version(target_binary(params, how)?)?
    if !want_present(params)? {
        if current == "" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if current == "" { return Ok(CheckResult::NotConfigured) }
    let wanted = param_str(params, "version", "")
    // An empty version means "any build of this channel", which is the only
    // honest reading offline: resolving "latest" needs the network.
    if wanted == "" { return Ok(CheckResult::AlreadyConfigured) }
    if current == wanted { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let how = method(params)?
    let present = want_present(params)?
    if how == "msi" { return if present { install_msi(params) } else { uninstall_msi(params) } }
    if how == "winget" { return if present { install_winget(params) } else { uninstall_winget(params) } }
    if how == "zip" { return if present { install_archive(params, "zip") } else { uninstall_archive(params) } }
    if how == "tarball" { return if present { install_archive(params, "tarball") } else { uninstall_archive(params) } }
    if present { return install_repo(params) }
    uninstall_repo(params)
}
