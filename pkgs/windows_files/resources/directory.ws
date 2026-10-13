use value
use fs
use env
use log
use common

// Directories an :absent step never deletes, relative to the system drive
// root (compared case-insensitively). Drive roots and UNC share roots are
// refused separately.
fn protected_dirs() -> List[string] {
    ["windows", "program files", "program files (x86)", "programdata", "users", "users\\public",
     "users\\default", "users\\all users", "recovery", "boot", "system volume information", "$recycle.bin",
     "perflogs", "documents and settings"]
}

// :absent is a recursive delete, so it refuses a drive or share root, the
// system directories above, a user profile root (C:\Users\<name>), the
// directories the environment names (SystemRoot, ProgramFiles, ...), and a
// link, which would be followed nowhere but is not this resource's to
// remove (use windows_files.symlink).
fn guard_delete(p: string) -> Result[unit, string] {
    let n = common::norm_path(p)
    let refuse = "refusing to delete '" + p + "'"
    if n.len() <= 3 && n.slice(1, 2) == ":" { return Err(refuse + ": it is a drive root") }
    if n.starts_with("\\\\") && n.slice(2, n.len()).split("\\").len() <= 2 { return Err(refuse + ": it is a share root") }
    let rel = if n.len() > 3 && n.slice(1, 2) == ":" { n.slice(3, n.len()) } else { "" }
    for d in protected_dirs() {
        if rel == d { return Err(refuse + ": it is a system directory") }
    }
    let segs = rel.split("\\")
    if segs.len() == 2 && segs.get(0).unwrap_or("") == "users" { return Err(refuse + ": it is a user profile root") }
    for var in ["SystemRoot", "windir", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "PUBLIC", "USERPROFILE", "ALLUSERSPROFILE", "SystemDrive"] {
        if let Some(v) = env::get(var) {
            if v != "" && common::norm_path(v) == n { return Err(refuse + ": it is %" + var + "%") }
        }
    }
    if fs::read_link(p).is_ok() { return Err(refuse + ": it is a symbolic link or junction; use windows_files.symlink with ensure = :absent") }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    if !common::want_present(params)? {
        guard_delete(p)?
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if fs::is_file(p) { return Err("'" + p + "' exists and is a file, not a directory") }
    if fs::is_dir(p) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    if !common::want_present(params)? {
        guard_delete(p)?
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        if fs::is_file(p) { return Err("'" + p + "' is a file; use windows_files.file with ensure = :absent") }
        log::info("deleting directory " + p)
        fs::delete_dir(p)?
        return Ok(ApplyResult::Success)
    }
    if fs::is_file(p) { return Err("'" + p + "' exists and is a file, not a directory") }
    log::info("creating directory " + p)
    fs::mkdir(p)?
    Ok(ApplyResult::Success)
}
