use value
use fs
use path
use sys
use http
use hash
use archive
use json
use encoding
use common
use psget
use user_tree

fn name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    common::path_segment("name", n)?
    Ok(n)
}

fn version(params: Value) -> Result[string, string] {
    let v = common::param_str(params, "version", "")
    if v != "" {
        common::path_segment("version", v)?
        common::version_chars("version", v)?
    }
    Ok(v)
}

// The directory modules are installed under. `destination` wins; otherwise
// the scope's standard location, computed locally when `home` is given so it
// works without a PowerShell to ask (the guest agent's HOME is not the
// invoking user's). None when the PowerShell to ask is not installed.
fn modules_dir(params: Value) -> Result[Option[string], string] {
    let destination = common::param_str(params, "destination", "")
    if destination != "" { return Ok(Some(destination)) }
    let edition = common::param_str(params, "edition", "auto")
    if common::param_str(params, "scope", "current_user") == "all_users" {
        let script = "if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path $env:ProgramFiles 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path $env:ProgramFiles 'PowerShell\\Modules' }} else {{ Write-Output '/usr/local/share/powershell/Modules' }}"
        return common::query(edition, script)
    }
    let home = common::param_str(params, "home", "")
    if home != "" {
        if sys::family() == "windows" {
            let folder = if common::resolved_edition(edition) == "windows_powershell" { "WindowsPowerShell" } else { "PowerShell" }
            return Ok(Some(path::join(path::join(path::join(home, "Documents"), folder), "Modules")))
        }
        return Ok(Some(path::join(path::join(path::join(path::join(home, ".local"), "share"), "powershell"), "Modules")))
    }
    // No home: the account config-weave runs as, usually SYSTEM or root.
    let script = "if ($PSVersionTable.PSEdition -eq 'Desktop') {{ Join-Path ([Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')) 'WindowsPowerShell\\Modules' }} elseif ($IsWindows) {{ Join-Path ([Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')) 'PowerShell\\Modules' }} else {{ Join-Path $HOME '.local/share/powershell/Modules' }}"
    common::query(edition, script)
}

// The user root a :current_user module directory lives under (see
// user_tree), None for :all_users or an explicit `destination`.
fn user_root(params: Value) -> Option[string] {
    if common::param_str(params, "destination", "") != "" { return None }
    if common::param_str(params, "scope", "current_user") == "all_users" { return None }
    Some(user_tree::root_of(common::param_str(params, "home", "")))
}

fn require_modules_dir(params: Value) -> Result[string, string] {
    if let Some(dir) = modules_dir(params)? { return Ok(dir) }
    Err("cannot resolve the module directory: " + common::not_installed(common::param_str(params, "edition", "auto")))
}

// <Name>/<Version>/ is the layout Get-Module -ListAvailable expects for a
// versioned module; a module with no version sits flat under <Name>/.
fn target_dir(dir: string, params: Value) -> Result[string, string] {
    let root = path::join(dir, name(params)?)
    let v = version(params)?
    if v == "" { return Ok(root) }
    Ok(path::join(root, v))
}

// A module directory only counts as installed when it holds a manifest,
// a root module or a binary named after the module — PowerShell refuses to
// import one that does not.
fn has_module_file(dir: string, n: string) -> bool {
    if !fs::is_dir(dir) { return false }
    for suffix in [".psd1", ".psm1", ".dll"] {
        if fs::is_file(path::join(dir, n + suffix)) { return true }
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

// One line per file and directory, with each file's SHA-256: two trees with
// the same digest hold the same files with the same content.
fn tree_lines(dir: string, rel: string) -> Result[List[string], string] {
    let out: List[string] = []
    for entry in fs::list_dir(dir)? {
        let full = path::join(dir, entry)
        let r = if rel == "" { entry } else { rel + "/" + entry }
        if fs::is_dir(full) {
            out.push("d " + r)
            for line in tree_lines(full, r)? { out.push(line) }
        } else {
            out.push("f " + r + " " + hash::sha256_file(full)?)
        }
    }
    Ok(out)
}

fn tree_digest(dir: string) -> Result[string, string] { Ok(hash::sha256(tree_lines(dir, "")?.join("\n"))) }

// What an archive or URL install recorded about itself, kept outside the
// module so the module directory holds only the module.
fn record_path(target: string) -> string {
    let base = if sys::family() == "windows" { "C:/ProgramData/config-weave/module_from_path" } else { "/var/lib/config-weave/module_from_path" }
    base + "/" + hash::sha256(target).slice(0, 24) + ".json"
}

fn read_record(target: string) -> Value {
    let file = record_path(target)
    if !fs::is_file(file) { return Value::Null }
    let text = fs::read(file)
    if text.is_err() { return Value::Null }
    json::parse(text.unwrap()).unwrap_or(Value::Null)
}

fn rec(v: Value, key: string) -> string { v.get(key).unwrap_or(Value::String("")).as_string().unwrap_or("") }

fn read_manifest(file: string) -> Result[string, string] {
    // Windows PowerShell's New-ModuleManifest writes UTF-16LE with a BOM,
    // which from_utf16le strips.
    let bytes = fs::read_bytes(file)?
    if bytes.len() >= 2 && bytes[0] == 255 && bytes[1] == 254 { return encoding::from_utf16le(bytes) }
    let text = fs::read(file)?
    if text.starts_with("\u{FEFF}") { return Ok(text.slice(1, text.len())) }
    Ok(text)
}

// The ModuleVersion a manifest declares, or "" when there is no manifest or
// it names none.
fn manifest_version(dir: string, n: string) -> Result[string, string] {
    let file = path::join(dir, n + ".psd1")
    if !fs::is_file(file) { return Ok("") }
    for raw in read_manifest(file)?.split("\n") {
        let line = raw.trim()
        if line.to_lower().starts_with("moduleversion") {
            if let Some(eq) = line.find("=") {
                let v = line.slice(eq + 1, line.len()).trim()
                if let Some(hash_at) = v.find("#") { v = v.slice(0, hash_at).trim() }
                return Ok(v.replace("'", "").replace("\"", "").trim())
            }
        }
    }
    Ok("")
}

fn version_matches(dir: string, params: Value) -> Result[bool, string] {
    let v = version(params)?
    if v == "" { return Ok(true) }
    let declared = manifest_version(dir, name(params)?)?
    if declared == "" { return Ok(true) }
    Ok(psget::version_eq(declared, v))
}

fn is_url(source: string) -> bool { source.starts_with("http://") || source.starts_with("https://") }

// Resolves `source` to a directory holding the module's files, unpacking and
// downloading into `work` as needed.
fn staged_source(params: Value, work: string) -> Result[string, string] {
    let source = common::param_str(params, "source", "")
    if source == "" { return Err("'source' is required when ensure is :present") }
    let expected = common::param_str(params, "sha256", "")

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

    if !common::param_bool(params, "strip_root", false) { return Ok(unpacked) }
    let entries = fs::list_dir(unpacked)?
    if entries.len() != 1 { return Err("strip_root needs the archive to hold exactly one top-level directory, found " + str(entries.len()) + " entries") }
    let inner = path::join(unpacked, entries[0])
    if !fs::is_dir(inner) { return Err("strip_root needs the archive's single top-level entry to be a directory") }
    Ok(inner)
}

// Whether the installed tree is exactly what `source` provides. A local
// directory is compared file by file. An archive or URL is compared through
// the record its install wrote: the same source, the same archive (re-hashed
// when it is local), and an installed tree nobody has changed since. A URL
// with no `sha256` cannot be re-checked without downloading it; set sha256
// to make a changed upstream archive drift.
fn content_matches(params: Value, target: string) -> Result[bool, string] {
    let source = common::param_str(params, "source", "")
    common::require("source", source)?
    if !is_url(source) && fs::is_dir(source) {
        return Ok(tree_digest(source)? == tree_digest(target)?)
    }
    let record = read_record(target)
    if record.is_null() { return Ok(false) }
    if rec(record, "source") != source { return Ok(false) }
    if rec(record, "sha256") != common::param_str(params, "sha256", "").trim().to_lower() { return Ok(false) }
    if rec(record, "strip_root") != str(common::param_bool(params, "strip_root", false)) { return Ok(false) }
    if !is_url(source) {
        if !fs::is_file(source) { return Err("source '" + source + "' is neither a file nor a directory") }
        if rec(record, "archive") != hash::sha256_file(source)? { return Ok(false) }
    }
    Ok(rec(record, "tree") == tree_digest(target)?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let n = name(params)?
    version(params)?
    let present = common::want_present(params)?
    let resolved = modules_dir(params)?
    if resolved.is_none() {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let dir = resolved.unwrap()
    let target = target_dir(dir, params)?
    // A link in the user's tree on the way to the module is an error, not
    // drift: apply refuses to delete or copy through it.
    user_tree::guard(user_root(params), target)?
    if !present {
        // Removing a versioned install only removes that version; removing an
        // unversioned one takes the whole module.
        let doomed = if version(params)? == "" { path::join(dir, n) } else { target }
        if fs::exists(doomed) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !has_module_file(target, n) { return Ok(CheckResult::NotConfigured) }
    if !version_matches(target, params)? { return Ok(CheckResult::NotConfigured) }
    if !content_matches(params, target)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let n = name(params)?
    let v = version(params)?
    let dir = require_modules_dir(params)?
    let root = path::join(dir, n)
    let target = target_dir(dir, params)?
    let user = user_root(params)
    user_tree::guard(user, target)?

    if !common::want_present(params)? {
        let doomed = if v == "" { root } else { target }
        if fs::is_dir(doomed) { fs::delete_dir(doomed)? }
        let record = record_path(target)
        if fs::is_file(record) { fs::delete(record)? }
        // A version directory removed from an otherwise empty module leaves a
        // stub that would still shadow a later install.
        if v != "" && fs::is_dir(root) && fs::list_dir(root)?.is_empty() { fs::delete_dir(root)? }
        return Ok(ApplyResult::Success)
    }

    let work = fs::temp_dir()?
    let staged = staged_source(params, work)
    if let Err(e) = staged {
        fs::delete_dir(work)?
        return Err(e)
    }
    let from = staged.unwrap()
    // The version directory must agree with the manifest, or PowerShell
    // ignores the module.
    let declared = manifest_version(from, n)
    let mismatch = if let Ok(d) = declared { v != "" && d != "" && !psget::version_eq(d, v) } else { false }
    if mismatch {
        fs::delete_dir(work)?
        return Err("the manifest " + n + ".psd1 declares ModuleVersion " + declared.unwrap() + ", but version is '" + v + "' — PowerShell ignores a module whose folder and manifest versions differ")
    }
    // The archive digest is taken now, from the file that was actually
    // extracted.
    let source = common::param_str(params, "source", "")
    let archive_sha = ""
    if !is_url(source) && fs::is_file(source) { archive_sha = hash::sha256_file(source)? }
    // Replaced rather than merged, so a shrinking module does not leave
    // orphaned files behind.
    if fs::is_dir(target) { fs::delete_dir(target)? }
    // copy_tree creates the missing directories: check again first, so a
    // link planted since the check above is not created through
    let guarded = user_tree::guard(user, target)
    if let Err(e) = guarded {
        fs::delete_dir(work)?
        return Err(e)
    }
    let copied = copy_tree(from, target)
    fs::delete_dir(work)?
    copied?
    if !has_module_file(target, n) {
        return Err("nothing named '" + n + ".psd1', '" + n + ".psm1' or '" + n + ".dll' landed in '" + target + "' — PowerShell cannot import a module directory without one")
    }
    let record = record_path(target)
    let parent = path::parent(record)
    if parent != "" { fs::mkdir(parent)? }
    fs::write(record, json::to_string(Value::Map(#{
        "source": Value::String(source),
        "sha256": Value::String(common::param_str(params, "sha256", "").trim().to_lower()),
        "strip_root": Value::String(str(common::param_bool(params, "strip_root", false))),
        "archive": Value::String(archive_sha),
        "tree": Value::String(tree_digest(target)?)
    })) + "\n")?
    Ok(ApplyResult::Success)
}
