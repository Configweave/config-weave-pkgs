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

fn entry(params: Value) -> string {
    param_str(params, "spec", "") + " " + param_str(params, "mountpoint", "") + " " + param_str(params, "fstype", "") + " " + param_str(params, "options", "defaults") + " " + str(param_int(params, "dump", 0)) + " " + str(param_int(params, "pass", 0))
}

fn has_entry(text: string, line: string) -> bool {
    for l in text.split("\n") { if l.trim() == line { return true } }
    false
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn check(params: Value) -> Result[CheckResult, string] {
    let line = entry(params)
    if param_str(params, "spec", "") == "" || param_str(params, "mountpoint", "") == "" || param_str(params, "fstype", "") == "" {
        return Err("spec, mountpoint and fstype are required")
    }
    if fs::is_file("/etc/fstab") && has_entry(fs::read("/etc/fstab")?, line) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let line = entry(params)
    let text = if fs::is_file("/etc/fstab") { fs::read("/etc/fstab")? } else { "" }
    if !has_entry(text, line) {
        let sep = if text == "" || text.ends_with("\n") { "" } else { "\n" }
        fs::write("/etc/fstab", text + sep + line + "\n")?
    }
    if param_bool(params, "mount", false) {
        let out = shell::bash("mount " + q(param_str(params, "mountpoint", "")), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}

