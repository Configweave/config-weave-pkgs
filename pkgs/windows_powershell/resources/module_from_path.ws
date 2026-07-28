use value
use fs
use path
use shell
use sys
use http
use hash
use archive

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

fn resolved_edition(edition: string) -> string {
    if edition != "auto" { return edition }
    if sys::family() == "windows" { "windows_powershell" } else { "pwsh" }
}

// The MSI's PATH change is invisible to an already-running process, so a
// PowerShell installed earlier in this same run cannot be found by name.
// The well-known install roots are probed before falling back to PATH.
fn pwsh_binary(preview: bool) -> string {
    if sys::family() != "windows" {
        if preview { return "pwsh-preview" }
        return "pwsh"
    }
    let pattern = if preview { "C:\\Program Files\\PowerShell\\*-preview\\pwsh.exe" } else { "C:\\Program Files\\PowerShell\\*\\pwsh.exe" }
    if let Ok(found) = fs::glob(pattern) {
        let best = ""
        for candidate in found {
            if !preview && candidate.contains("-preview") { continue }
            best = candidate
        }
        if best != "" { return best }
    }
    "pwsh"
}

fn ps_exe(edition: string) -> string {
    let resolved = resolved_edition(edition)
    if resolved == "windows_powershell" { return "powershell" }
    pwsh_binary(resolved == "pwsh_preview")
}

fn dq(s: string) -> string { "\"" + s + "\"" }

// Every PowerShell invocation carries a timeout. A resource that can hang
// forever is a defect: the timeout kills the child and surfaces an Err, which
// the engine reports as a failed step naming this resource.
fn run_ps(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    let out = shell::run(dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file), Value::Map(#{ "timeout": Value::Int(300) }))
    fs::delete_dir(dir)?
    out
}

// The directory modules are installed under. `destination` wins; otherwise
// the scope's standard location, computed locally when `home` is given so it
// works without a PowerShell to ask (the guest agent's HOME is not the
// invoking user's).
fn modules_dir(params: Value) -> Result[string, string] {
    let destination = param_str(params, "destination", "")
    if destination != "" { return Ok(destination) }
    let edition = param_str(params, "edition", "auto")
    if param_str(params, "scope", "current_user") == "all_users" {
        let script = "if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path $env:ProgramFiles 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path $env:ProgramFiles 'PowerShell\\Modules' }} else {{ Write-Output '/usr/local/share/powershell/Modules' }}"
        let out = run_ps(edition, script)?
        if !out.success { return Err("cannot resolve the machine-wide module directory: " + out.stderr.trim()) }
        return Ok(out.stdout.trim())
    }
    let home = param_str(params, "home", "")
    if home != "" {
        if sys::family() == "windows" {
            let folder = if resolved_edition(edition) == "windows_powershell" { "WindowsPowerShell" } else { "PowerShell" }
            return Ok(path::join(path::join(path::join(home, "Documents"), folder), "Modules"))
        }
        return Ok(path::join(path::join(path::join(path::join(home, ".local"), "share"), "powershell"), "Modules"))
    }
    let script = "if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\\Modules' }} else {{ Join-Path $HOME '.local/share/powershell/Modules' }}"
    let out = run_ps(edition, script)?
    if !out.success { return Err("cannot resolve the user module directory: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn module_root(params: Value) -> Result[string, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    Ok(path::join(modules_dir(params)?, name))
}

// <Name>/<Version>/ is the layout Get-Module -ListAvailable expects for a
// versioned module; a module with no version sits flat under <Name>/.
fn target_dir(params: Value) -> Result[string, string] {
    let root = module_root(params)?
    let version = param_str(params, "version", "")
    if version == "" { return Ok(root) }
    Ok(path::join(root, version))
}

// A module directory only counts as installed when it holds a manifest,
// a root module or a binary named after the module — PowerShell refuses to
// import one that does not.
fn has_module_file(dir: string, name: string) -> bool {
    if !fs::is_dir(dir) { return false }
    for suffix in [".psd1", ".psm1", ".dll"] {
        if fs::is_file(path::join(dir, name + suffix)) { return true }
    }
    false
}

fn copy_tree(from: string, to: string) -> Result[unit, string] {
    fs::mkdir(to)?
    for entry in fs::list_dir(from)? {
        let src = path::join(from, entry)
        let dst = path::join(to, entry)
        if fs::is_dir(src) { copy_tree(src, dst)? } else { fs::copy(src, dst)? }
    }
    Ok(())
}

// Resolves `source` to a directory holding the module's files, unpacking and
// downloading into `work` as needed.
fn staged_source(params: Value, work: string) -> Result[string, string] {
    let source = param_str(params, "source", "")
    if source == "" { return Err("'source' is required when ensure is :present") }
    let expected = param_str(params, "sha256", "")

    let local = source
    if source.starts_with("http://") || source.starts_with("https://") {
        let name = path::filename(source)
        let downloaded = path::join(work, if name == "" { "module-download" } else { name })
        http::download(source, downloaded, Value::Null)?
        local = downloaded
    }

    if fs::is_dir(local) {
        if expected != "" { return Err("'sha256' can only verify an archive, not the directory '" + local + "'") }
        return Ok(local)
    }
    if !fs::is_file(local) { return Err("source '" + local + "' is neither a file nor a directory") }
    if expected != "" {
        let actual = hash::sha256_file(local)?
        if actual != expected.trim().to_lower() {
            return Err("sha256 mismatch for '" + local + "': expected " + expected + ", got " + actual)
        }
    }

    let unpacked = path::join(work, "unpacked")
    fs::mkdir(unpacked)?
    // A .nupkg is a zip; archive::extract dispatches on the extension, so it
    // is extracted explicitly.
    if local.ends_with(".nupkg") || local.ends_with(".zip") {
        archive::extract_zip(local, unpacked)?
    } else {
        archive::extract(local, unpacked)?
    }

    if !param_bool(params, "strip_root", false) { return Ok(unpacked) }
    let entries = fs::list_dir(unpacked)?
    if entries.len() != 1 { return Err("strip_root needs the archive to hold exactly one top-level directory, found " + str(entries.len()) + " entries") }
    let inner = path::join(unpacked, entries[0])
    if !fs::is_dir(inner) { return Err("strip_root needs the archive's single top-level entry to be a directory") }
    Ok(inner)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    // Resolving the module directory runs the target PowerShell, which may
    // not be installed yet: run 1 checks every step before the install step
    // has applied. That is "not configured", not a failure.
    if modules_dir(params).is_err() {
        if want_present(params)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !want_present(params)? {
        // Removing a versioned install only removes that version; removing an
        // unversioned one takes the whole module.
        let version = param_str(params, "version", "")
        let gone = if version == "" { !fs::exists(module_root(params)?) } else { !fs::exists(target_dir(params)?) }
        if gone { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if has_module_file(target_dir(params)?, name) { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }

    if !want_present(params)? {
        let version = param_str(params, "version", "")
        let doomed = if version == "" { module_root(params)? } else { target_dir(params)? }
        if fs::is_dir(doomed) { fs::delete_dir(doomed)? }
        // A version directory removed from an otherwise empty module leaves a
        // stub that would still shadow a later install.
        if version != "" {
            let root = module_root(params)?
            if fs::is_dir(root) && fs::list_dir(root)?.is_empty() { fs::delete_dir(root)? }
        }
        return Ok(ApplyResult::Success)
    }

    let work = fs::temp_dir()?
    let staged = staged_source(params, work)
    if let Err(e) = staged {
        fs::delete_dir(work)?
        return Err(e)
    }
    let target = target_dir(params)?
    // Replaced rather than merged, so a shrinking module does not leave
    // orphaned files behind.
    if fs::is_dir(target) { fs::delete_dir(target)? }
    let copied = copy_tree(staged.unwrap(), target)
    fs::delete_dir(work)?
    copied?
    if !has_module_file(target, name) {
        return Err("nothing named '" + name + ".psd1', '" + name + ".psm1' or '" + name + ".dll' landed in '" + target + "' — PowerShell cannot import a module directory without one")
    }
    Ok(ApplyResult::Success)
}
