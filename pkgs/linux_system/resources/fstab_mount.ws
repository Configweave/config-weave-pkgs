use value
use fs
use log
use common

// fstab(5) and /proc/mounts escape a space, tab or backslash in a field as
// an octal \NNN sequence. The kernel escapes exactly these (and newline),
// so a fixed table covers both directions; backslash goes last on decode
// and first on encode so an escaped backslash is never re-read.
fn decode(f: string) -> string {
    f.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")
}

fn encode(f: string) -> string {
    f.replace("\\", "\\134").replace(" ", "\\040").replace("\t", "\\011")
}

// "/mnt/x/" and "/mnt/x" are one mount point.
fn norm_mp(mp: string) -> string {
    if mp.len() > 1 && mp.ends_with("/") { return mp.slice(0, mp.len() - 1) }
    mp
}

fn validate(params: Value, present: bool) -> Result[unit, string] {
    let mp = common::param_str(params, "mountpoint", "")
    if mp == "" { return Err("missing 'mountpoint' parameter") }
    common::one_line("mountpoint", mp)?
    if !mp.starts_with("/") && mp != "none" && mp != "swap" {
        return Err("'mountpoint' must be an absolute path, or none/swap for a swap entry")
    }
    if !present { return Ok(()) }
    let spec = common::param_str(params, "spec", "")
    let fstype = common::param_str(params, "fstype", "")
    if spec == "" || fstype == "" { return Err("spec and fstype are required when ensure is :present") }
    common::one_line("spec", spec)?
    // fstype and options cannot carry an escape, so whitespace there would
    // split the line into extra fields and corrupt the entry
    for kv in [["fstype", fstype], ["options", common::param_str(params, "options", "defaults")]] {
        if kv[1] == "" || common::has_space(kv[1]) || kv[1].contains("\n") || kv[1].contains("\r") {
            return Err("'" + kv[0] + "' must be non-empty and contain no whitespace")
        }
    }
    if common::param_int(params, "dump", 0) < 0 || common::param_int(params, "pass", 0) < 0 {
        return Err("'dump' and 'pass' must not be negative")
    }
    if common::param_bool(params, "mount", false) && !mp.starts_with("/") {
        return Err("mount = true needs an absolute mountpoint")
    }
    Ok(())
}

// The six fields as they are written to fstab.
fn desired(params: Value) -> List[string] {
    [
        encode(common::param_str(params, "spec", "")),
        encode(norm_mp(common::param_str(params, "mountpoint", ""))),
        common::param_str(params, "fstype", ""),
        common::param_str(params, "options", "defaults"),
        str(common::param_int(params, "dump", 0)),
        str(common::param_int(params, "pass", 0)),
    ]
}

// fstab separates fields with runs of spaces or tabs. Missing dump and
// pass fields read as 0, as mount does.
fn fields(line: string) -> List[string] {
    let out = []
    for f in line.replace("\t", " ").split(" ") {
        if f != "" { out.push(f) }
    }
    if out.len() == 4 { out.push("0") }
    if out.len() == 5 { out.push("0") }
    out
}

// A line that actually declares a mount. Comments and blanks are not
// entries, and are carried through edits untouched.
fn is_entry(line: string) -> bool {
    let t = line.trim()
    t != "" && !t.starts_with("#")
}

// The mount point is field 2, and is what identifies an entry: a path can be
// mounted only once, so it is the key both for replacing an entry whose
// options changed and for removing one.
fn entry_mountpoint(line: string) -> string {
    norm_mp(decode(fields(line).get(1).unwrap_or("")))
}

fn entries_for(text: string, mp: string) -> List[List[string]] {
    let out = []
    for l in text.split("\n") {
        if is_entry(l) && entry_mountpoint(l) == mp { out.push(fields(l)) }
    }
    out
}

fn fstab_text() -> Result[string, string] {
    if fs::is_file("/etc/fstab") { return fs::read("/etc/fstab") }
    Ok("")
}

// /proc/mounts uses the same field layout and escapes as fstab.
fn mounted(mp: string) -> Result[bool, string] {
    if !fs::is_file("/proc/mounts") { return Ok(false) }
    Ok(!entries_for(fs::read("/proc/mounts")?, mp).is_empty())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let mp = norm_mp(common::param_str(params, "mountpoint", ""))
    let manage_mount = common::param_bool(params, "mount", false)
    let found = entries_for(fstab_text()?, mp)
    if !present {
        if !found.is_empty() { return Ok(CheckResult::NotConfigured) }
        if manage_mount && mounted(mp)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // Exactly one entry, field for field: a second entry for the same mount
    // point is drift too, since mount would act on whichever comes last.
    if found.len() != 1 || found[0] != desired(params) { return Ok(CheckResult::NotConfigured) }
    if manage_mount && !mounted(mp)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let present = common::want_present(params)?
    validate(params, present)?
    let mp = norm_mp(common::param_str(params, "mountpoint", ""))
    let manage_mount = common::param_bool(params, "mount", false)
    // Unmount before the entry goes, so the running system and fstab agree.
    if !present && manage_mount && mounted(mp)? {
        log::info("unmounting " + mp)
        common::run("umount " + mp, "umount -- " + common::q(mp))?
    }
    let text = fstab_text()?
    let before = entries_for(text, mp)
    let want = desired(params)
    let unchanged = present && before.len() == 1 && before[0] == want
    if !unchanged && !(!present && before.is_empty()) {
        // Drop every entry for this mount point, keeping comments and every
        // other entry exactly where they were, then append the one wanted.
        let kept = []
        for l in text.split("\n") {
            if !(is_entry(l) && entry_mountpoint(l) == mp) { kept.push(l) }
        }
        let rebuilt = kept.join("\n")
        if present {
            let sep = if rebuilt == "" || rebuilt.ends_with("\n") { "" } else { "\n" }
            log::info("writing fstab entry for " + mp)
            common::write_atomic("/etc/fstab", rebuilt + sep + want.join(" ") + "\n")?
        } else {
            log::info("removing fstab entry for " + mp)
            common::write_atomic("/etc/fstab", rebuilt)?
        }
    }
    if present && manage_mount {
        if !mounted(mp)? {
            fs::mkdir(mp)?
            log::info("mounting " + mp)
            common::run("mount " + mp, "mount -- " + common::q(mp))?
        } else if !unchanged {
            // Already mounted from an older entry. A new device or type
            // needs a fresh mount; anything else is an option change that
            // remount applies in place.
            let old = before.get(0).unwrap_or([])
            if old.get(0).unwrap_or("") != want[0] || old.get(2).unwrap_or("") != want[2] {
                log::info("remounting " + mp + " from its new device")
                common::run("umount " + mp, "umount -- " + common::q(mp))?
                common::run("mount " + mp, "mount -- " + common::q(mp))?
            } else {
                // The options go on the command line: not every mount
                // (busybox, minimal shims) reads them back from fstab.
                log::info("remounting " + mp + " with its new options")
                common::run("remount " + mp, "mount -o " + common::q("remount," + want[3]) + " -- " + common::q(mp))?
            }
        }
    }
    Ok(ApplyResult::Success)
}
