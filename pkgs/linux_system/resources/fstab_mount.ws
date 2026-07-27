use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
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

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn entry(params: Value) -> string {
    param_str(params, "spec", "") + " " + param_str(params, "mountpoint", "") + " " + param_str(params, "fstype", "") + " " + param_str(params, "options", "defaults") + " " + str(param_int(params, "dump", 0)) + " " + str(param_int(params, "pass", 0))
}

fn has_entry(text: string, line: string) -> bool {
    for l in text.split("\n") { if l.trim() == line { return true } }
    false
}

// fstab separates fields with runs of spaces or tabs.
fn fields(line: string) -> List[string] {
    let out = []
    for f in line.replace("\t", " ").split(" ") {
        if f != "" { out.push(f) }
    }
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
    let f = fields(line)
    if f.len() >= 2 { return f.get(1).unwrap_or("") }
    ""
}

fn fstab_text() -> Result[string, string] {
    if fs::is_file("/etc/fstab") { return fs::read("/etc/fstab") }
    Ok("")
}

fn listed(text: string, mountpoint: string) -> bool {
    for l in text.split("\n") {
        if is_entry(l) && entry_mountpoint(l) == mountpoint { return true }
    }
    false
}

// /proc/mounts uses the same field layout as fstab.
fn mounted(mountpoint: string) -> Result[bool, string] {
    if !fs::is_file("/proc/mounts") { return Ok(false) }
    Ok(listed(fs::read("/proc/mounts")?, mountpoint))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let mountpoint = param_str(params, "mountpoint", "")
    if mountpoint == "" { return Err("missing 'mountpoint' parameter") }
    let text = fstab_text()?
    if !want_present(params)? {
        if listed(text, mountpoint) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if param_str(params, "spec", "") == "" || param_str(params, "fstype", "") == "" {
        return Err("spec and fstype are required when ensure is :present")
    }
    // An entry for this mount point that differs in any field is drift, not a
    // match, so the exact-line test stands: apply replaces it rather than
    // appending a second entry for the same path.
    if has_entry(text, entry(params)) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let mountpoint = param_str(params, "mountpoint", "")
    if mountpoint == "" { return Err("missing 'mountpoint' parameter") }
    let present = want_present(params)?
    if present && (param_str(params, "spec", "") == "" || param_str(params, "fstype", "") == "") {
        return Err("spec and fstype are required when ensure is :present")
    }
    // Unmount before the entry goes, so the running system and fstab agree.
    if !present && param_bool(params, "mount", false) && mounted(mountpoint)? {
        let out = shell::bash("umount " + q(mountpoint), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    let text = fstab_text()?
    // Drop any existing entry for this mount point, keeping comments and
    // every other entry exactly where they were.
    let kept = []
    for l in text.split("\n") {
        if !(is_entry(l) && entry_mountpoint(l) == mountpoint) { kept.push(l) }
    }
    let rebuilt = kept.join("\n")
    if present {
        let sep = if rebuilt == "" || rebuilt.ends_with("\n") { "" } else { "\n" }
        fs::write("/etc/fstab", rebuilt + sep + entry(params) + "\n")?
    } else {
        fs::write("/etc/fstab", rebuilt)?
    }
    if present && param_bool(params, "mount", false) {
        let out = shell::bash("mount " + q(mountpoint), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}
