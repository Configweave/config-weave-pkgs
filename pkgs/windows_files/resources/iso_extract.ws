use value
use fs
use path
use log
use common
use iso

// The completion marker. It is written only after a whole copy succeeded,
// and holds the identity of the image it came from, so a copy that stopped
// part way, or a different image at `path`, is drift.
fn marker(dest: string) -> string { path::join(dest, ".config-weave-iso") }

// The image's identity: its path, size and modification time. A new
// download renamed into place gets a new modification time, so replacing
// the image triggers a new extract without hashing gigabytes on every run.
fn identity(p: string) -> Result[string, string] {
    let meta = fs::metadata(p)?
    let size = meta.get("size").unwrap_or(Value::Null).as_int().unwrap_or(-1)
    let modified = meta.get("modified").unwrap_or(Value::Null).as_int().unwrap_or(-1)
    Ok(common::norm_path(p) + "|" + str(size) + "|" + str(modified))
}

fn destination(params: Value) -> Result[string, string] {
    let d = common::param_str(params, "destination", "")
    common::require_path("destination", d)?
    let d2 = d.replace("/", "\\")
    while d2.len() > 3 && d2.ends_with("\\") { d2 = d2.slice(0, d2.len() - 1) }
    // The copy mirrors the image, deleting whatever else is there, so the
    // same places a recursive delete refuses are refused here.
    common::guard_delete(d2)?
    Ok(d2)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let dest = destination(params)?
    if !common::want_present(params)? {
        if fs::exists(dest) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if fs::is_file(dest) { return Err("'" + dest + "' is a file, not a directory") }
    let have = fs::read(marker(dest)).unwrap_or("").trim()
    // Deleting the image once it has been extracted is fine: with no image
    // to compare against, a finished extract of this path stands.
    if !fs::is_file(p) {
        if have.starts_with(common::norm_path(p) + "|") { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if have != identity(p)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let dest = destination(params)?
    if !common::want_present(params)? {
        if !fs::exists(dest) { return Ok(ApplyResult::Success) }
        log::info("deleting " + dest)
        fs::delete_dir(dest)?
        return Ok(ApplyResult::Success)
    }
    if !fs::is_file(p) { return Err("disk image '" + p + "' does not exist") }
    if fs::is_file(dest) { return Err("'" + dest + "' is a file, not a directory") }
    let id = identity(p)?
    fs::mkdir(dest)?
    if fs::exists(marker(dest)) { fs::delete(marker(dest))? }
    log::info("extracting " + p + " -> " + dest)
    // An image that is already mounted (by iso_mount, say) is used where it
    // is and left mounted; one this step mounted is always dismounted.
    // robocopy /MIR makes the destination an exact copy, and /A-:R drops
    // the read-only attribute every file on optical media carries.
    common::ps_run("extracting " + p, "$p = " + common::ps_q(p) + "\n$dest = " + common::ps_q(dest) + "\n" + iso::ps_funcs() +
        "$mine = -not (Iso-Image $p).Attached\n" +
        "if ($mine) {{ Mount-DiskImage -ImagePath $p | Out-Null }}\n" +
        "try {{\n" +
        "  $l = Iso-Letter $p\n" +
        "  if ($l -eq '') {{ throw ('''' + $p + ''' is mounted without a drive letter; give it one (windows_files.iso_mount drive_letter) or dismount it') }}\n" +
        "  $log = robocopy ($l + ':\\') $dest /MIR /XF .config-weave-iso /A-:R /DCOPY:T /R:2 /W:2 /MT:8 /NP /NFL /NDL /NJH\n" +
        "  if ($LASTEXITCODE -ge 8) {{ throw ('robocopy failed (exit ' + $LASTEXITCODE + '): ' + (($log | Where-Object {{ $_ -match '\\S' }}) -join ' / ')) }}\n" +
        // robocopy copies the directories' read-only flag even with /DCOPY:T.
        "  foreach ($d in @(Get-Item -LiteralPath $dest -Force) + @(Get-ChildItem -LiteralPath $dest -Recurse -Directory -Force)) {{\n" +
        "    if ($d.Attributes -band [IO.FileAttributes]::ReadOnly) {{ $d.Attributes = $d.Attributes -bxor [IO.FileAttributes]::ReadOnly }}\n" +
        "  }}\n" +
        "}} finally {{\n" +
        "  if ($mine) {{ Dismount-DiskImage -ImagePath $p | Out-Null }}\n" +
        "}}\n")?
    fs::write(marker(dest), id)?
    Ok(ApplyResult::Success)
}
