use value
use fs
use path
use shell
use sys
use http
use archive
use json
use log
use common
use vrange

// Every external command carries a timeout. A resource that can hang forever
// is a defect: the timeout kills the child and surfaces an Err, which the
// engine reports as a failed step naming this resource.
fn opts(seconds: int) -> Value { Value::Map(#{ "timeout": Value::Int(seconds) }) }

fn preview(params: Value) -> bool { common::param_str(params, "channel", "stable") == "preview" }

// On Linux the LTS release is its own distro package, powershell-lts, which
// installs into /opt/microsoft/powershell/7-lts and is reached as pwsh-lts.
// On Windows an LTS release is the same MSI, zip and winget package as any
// other release — the same product, the same root — so `version` alone
// selects it there.
fn lts(params: Value) -> bool { common::param_str(params, "channel", "stable") == "lts" }

// Validated once: the version reaches download URLs, package specs and
// command lines. By the time anything but check() and apply() reads it,
// "latest" and a range have been replaced by the release they resolve to
// (see effective). "*" means the same as empty: any build.
fn version(params: Value) -> Result[string, string] {
    let v = common::param_str(params, "version", "")
    if vrange::any(v) { return Ok("") }
    if is_range(v) {
        vrange::validate("version", v)?
        return Ok(v)
    }
    common::version_chars("version", v)?
    Ok(v)
}

fn wants_latest(params: Value) -> bool { common::param_str(params, "version", "") == "latest" }

// A version that names more than one release (7, 7.4, 7.4.x, ^7, >=7.4
// <7.6): neither "latest", any build, one exact release, nor a pin that is
// not range syntax.
fn is_range(v: string) -> bool { v != "latest" && !vrange::any(v) && !vrange::exact(v) && !vrange::opaque(v) }

fn wants_range(params: Value) -> bool { is_range(common::param_str(params, "version", "")) }

// Every release PowerShell has tagged, from the ref advertisement of its git
// repository: the GitHub API rate-limits, and tools/metadata.json names only
// the current release of each channel.
fn tags_url() -> string { "https://github.com/PowerShell/PowerShell.git/info/refs?service=git-upload-pack" }

fn release_tags() -> Result[List[string], string] {
    let what = "listing PowerShell releases from " + tags_url()
    let hint = " (a version range needs that URL reachable; pin an exact version, or set url, to work offline)"
    let last = ""
    let attempt = 1
    while attempt <= 3 {
        let resp = http::get(tags_url(), Value::Map(#{ "timeout": Value::Int(120), "redirects": Value::Bool(true) }))
        if let Ok(r) = resp {
            if r.status == 200 {
                let found: List[string] = []
                for line in r.body.split("\n") {
                    if let Some(i) = line.find("refs/tags/v") {
                        let tag = line.slice(i + 11, line.len()).trim().replace("^{{}}", "")
                        if tag != "" && !found.contains(tag) { found.push(tag) }
                    }
                }
                if found.is_empty() { return Err(what + " failed: the answer lists no release tags" + hint) }
                return Ok(found)
            }
            last = "HTTP " + str(r.status)
            if r.status >= 400 && r.status < 500 { attempt = 3 }
        } else if let Err(e) = resp {
            last = e
        }
        attempt = attempt + 1
        if attempt <= 3 { time::sleep(3000) }
    }
    Err(what + " failed: " + last + hint)
}

// The newest tagged release that satisfies the range. A pre-release counts
// only when the range names one, as in npm.
fn resolve_range(params: Value) -> Result[string, string] {
    let want = common::param_str(params, "version", "")
    let v = vrange::pick("pwsh_installed", release_tags()?, want, "PowerShell's release tags")?
    common::version_chars("the resolved release", v)?
    Ok(v)
}

// The current release of the channel (common::latest_release). A lookup
// that fails is an error in check and apply alike, naming the URL: "latest"
// cannot be decided offline, and passing silently would hide that the step
// is no longer tracking it.
fn resolve_latest(params: Value) -> Result[string, string] {
    common::latest_release(common::param_str(params, "channel", "stable"), common::param_str(params, "latest_url", ""))
}

// The params with "latest" replaced by the release it resolves to, so every
// helper below sees a concrete version. Removal needs no release: it removes
// whatever build is there, so it never touches the network.
fn effective(params: Value, how: string, present: bool) -> Result[Value, string] {
    if wants_range(params) {
        range_root(params, how)?
        // An explicit url is what the archive and MSI methods install, so
        // there is nothing to resolve; removal removes whatever is there.
        let archive_like = how == "msi" || how == "zip" || how == "tarball"
        if !present || (archive_like && common::param_str(params, "url", "") != "") { return Ok(params) }
        let m = params.as_map().unwrap_or(#{})
        m.insert("version", Value::String(resolve_range(params)?))
        return Ok(Value::Map(m))
    }
    if !wants_latest(params) { return Ok(params) }
    if (how == "zip" || how == "tarball") && common::param_str(params, "install_root", "") == "" {
        return Err("'install_root' is required with version = \"latest\" for the :" + how + " method — the default root is named for one version, and the latest build replaces the one in a fixed root")
    }
    let m = params.as_map().unwrap_or(#{})
    let v = if present { resolve_latest(params)? } else { "" }
    m.insert("version", Value::String(v))
    Ok(Value::Map(m))
}

// A range with an archive method needs its own root, as "latest" does: the
// default root is named for one version.
fn range_root(params: Value, how: string) -> Result[unit, string] {
    if (how == "zip" || how == "tarball") && common::param_str(params, "install_root", "") == "" {
        return Err("'install_root' is required with a version range for the :" + how + " method — the default root is named for one version, and the newest matching build replaces the one in a fixed root")
    }
    Ok(())
}

fn major(params: Value) -> Result[string, string] {
    let v = version(params)?
    if v == "" { return Ok("7") }
    // A range's MSI root is that of the first major it names (^7, 7.4.x,
    // >=7.4 <7.6 all live in ...\PowerShell\7).
    if is_range(v) {
        let digits = ""
        for c in v.chars() {
            if c >= '0' && c <= '9' { digits = digits + str(c) } else if digits != "" { break }
        }
        return Ok(if digits == "" { "7" } else { digits })
    }
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
    // winget publishes the preview only as an MSIX package, which never
    // lands in the MSI root check reads, so it could never converge.
    if resolved == "winget" && preview(params) {
        return Err("method :winget cannot install channel :preview: winget offers Microsoft.PowerShell.Preview only as an MSIX package, which does not install into C:\\Program Files\\PowerShell\\7-preview. Use :msi or :zip")
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
    if lts(params) { return Ok("pwsh-lts") }
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
    if v == "" { return Err("'version' or 'url' is required for the :" + how + " method — set version = \"latest\" to install the channel's current release") }
    // The Windows artefacts are named PowerShell-…, the Linux tarball
    // powershell-….
    let base = "https://github.com/PowerShell/PowerShell/releases/download/v" + v + "/"
    let arch = arch_tag()?
    if how == "msi" { return Ok(base + "PowerShell-" + v + "-win-" + arch + ".msi") }
    if how == "zip" { return Ok(base + "PowerShell-" + v + "-win-" + arch + ".zip") }
    Ok(base + "powershell-" + v + "-linux-" + arch + ".tar.gz")
}

// Retried and checked against `sha256` (when set) by http::download. The
// file lives in a temp directory that is deleted after the install.
fn download(params: Value, how: string, file: string) -> Result[unit, string] {
    let url = artefact_url(params, how)?
    let o = #{ "timeout": Value::Int(1800), "retries": Value::Int(3) }
    let expected = common::param_str(params, "sha256", "").trim()
    if expected != "" { o.insert("sha256", Value::String(expected)) }
    log::info("downloading " + url)
    let got = http::download(url, file, Value::Map(o))
    if let Ok(n) = got {
        if n > 0 { return Ok(()) }
        return Err("downloading " + url + " failed: the download was empty")
    } else if let Err(e) = got {
        if e.contains("404") { return Err("downloading " + url + " failed: the release has no such artefact (HTTP 404). PowerShell 7.7 previews, for example, ship no MSI; use :zip for them") }
        return Err(e)
    }
    Ok(())
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

fn winget_id(params: Value) -> string { "Microsoft.PowerShell" }

// winget is driven through the newest App Installer copy under WindowsApps
// (common::winget_ps), since SYSTEM has no winget on PATH. The MSI (wix)
// installer at machine scope is asked for explicitly: left to itself winget
// may pick the MSIX package, which never lands in the MSI's root that check
// reads. A build already installed at another version is replaced with
// --force.
fn install_winget(params: Value) -> Result[ApplyResult, string] {
    let installed = installed_version(target_binary(params, "winget")?)? != ""
    let script = common::winget_ps() +
        "$a = @('install', '--id', $env:CW_ID, '--source', 'winget', '--exact', '--silent', '--scope', 'machine', '--installer-type', 'wix', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')\n" +
        "if ([string]$env:CW_VERSION -ne '') {{ $a += @('--version', $env:CW_VERSION) }}\n" +
        "if ($env:CW_FORCE -eq '1') {{ $a += '--force' }}\n" +
        "& $winget @a\n" +
        "exit $LASTEXITCODE\n"
    let out = common::run_ps_streaming_env("windows_powershell", script, #{
        "CW_ID": Value::String(winget_id(params)),
        "CW_VERSION": Value::String(version(params)?),
        "CW_FORCE": Value::String(if installed { "1" } else { "0" })
    }, 2400)?
    winget_result("winget install " + winget_id(params), out)
}

fn uninstall_winget(params: Value) -> Result[ApplyResult, string] {
    let script = common::winget_ps() +
        "& $winget uninstall --id $env:CW_ID --exact --silent --accept-source-agreements --disable-interactivity\n" +
        "exit $LASTEXITCODE\n"
    let out = common::run_ps_streaming_env("windows_powershell", script, #{ "CW_ID": Value::String(winget_id(params)) }, 2400)?
    winget_result("winget uninstall " + winget_id(params), out)
}

fn winget_result(what: string, out: CmdOutput) -> Result[ApplyResult, string] {
    if out.code == common::winget_reboot_code() { return Ok(ApplyResult::RebootRequired) }
    if out.success || out.code == common::winget_no_upgrade_code() { return Ok(ApplyResult::Success) }
    if out.code == common::winget_missing_code() { return Err(what + " failed: winget is not installed or cannot start (as SYSTEM it also needs the Visual C++ 2015-2022 runtime; windows_packages.winget_installed provides both)") }
    Err(common::failure(what, out))
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
        if fs::lexists(link) { fs::delete(link)? }
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
    if lts(params) { return "powershell-lts" }
    "powershell"
}

// The package spec for a pinned version. packages.microsoft.com versions the
// deb as <version>-1.deb, a prerelease keeping its '-' (7.7.0-preview.5-1.deb);
// the rpm writes that '-' as '_' (7.7.0_preview.5).
fn apt_spec(params: Value) -> Result[string, string] {
    let v = version(params)?
    if v == "" { return Ok(package_name(params)) }
    Ok(package_name(params) + "=" + v + "-1.deb")
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
    let script = "set -e\n. /etc/os-release\nif command -v apt-get >/dev/null 2>&1; then\n  install -d /usr/share/keyrings\n  if [ ! -f /usr/share/keyrings/microsoft-prod.gpg ]; then\n    curl -fsSL --retry 3 --retry-all-errors https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg\n  fi\n  curl -fsSL --retry 3 --retry-all-errors -o /etc/apt/sources.list.d/microsoft-prod.list \"https://packages.microsoft.com/config/$ID/$VERSION_ID/prod.list\"\n  apt-get update -qq\n  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-downgrades " + apt + "\nelif command -v dnf >/dev/null 2>&1; then\n  rpm --import https://packages.microsoft.com/keys/microsoft.asc\n  curl -fsSL --retry 3 --retry-all-errors -o /etc/yum.repos.d/microsoft-prod.repo \"https://packages.microsoft.com/config/$ID/$VERSION_ID/prod.repo\" || curl -fsSL --retry 3 --retry-all-errors -o /etc/yum.repos.d/microsoft-prod.repo https://packages.microsoft.com/config/rhel/9/prod.repo\n  dnf install -y " + dnf + "\nelse\n  echo 'no supported package manager (apt-get or dnf) found' >&2\n  exit 1\nfi"
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
    let present = common::want_present(params)?
    version(params)?
    // A range is matched against the installed build as it stands; only
    // apply resolves it to a release, so check needs no network for it.
    if wants_range(params) { range_root(params, how)? }
    let p = if wants_range(params) { params } else { effective(params, how, present)? }
    let binary = target_binary(p, how)?
    let current = installed_version(binary)?
    if !present {
        if current == "" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if current == "" { return Ok(CheckResult::NotConfigured) }
    // A resolved "latest" is a floor, so a build newer than the published
    // release (a hotfix ahead of the metadata) is not downgraded. Otherwise
    // the build must satisfy the version range; empty accepts any build of
    // the channel.
    if wants_latest(params) {
        if common::version_ok(current, version(p)?, true) { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if vrange::satisfies("pwsh_installed", current, common::param_str(params, "version", ""), binary + "'s $PSVersionTable.PSVersion")? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let how = method(params)?
    let present = common::want_present(params)?
    version(params)?
    let p = effective(params, how, present)?
    if how == "msi" { return if present { install_msi(p) } else { uninstall_msi(p) } }
    if how == "winget" { return if present { install_winget(p) } else { uninstall_winget(p) } }
    if how == "zip" || how == "tarball" { return if present { install_archive(p, how) } else { uninstall_archive(p) } }
    if present { return install_repo(p) }
    uninstall_repo(p)
}
