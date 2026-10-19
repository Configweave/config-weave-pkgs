use value
use fs
use path
use shell

// Helpers shared by linux_system's resources. Imported with `use common`;
// nothing here is package-external.

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

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// A failed command's error: stderr, else stdout (init scripts and many
// tools report there), always with the exit code.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

fn output(what: string, cmd: string) -> Result[CmdOutput, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(out)
}

fn run(what: string, cmd: string) -> Result[unit, string] {
    let out = output(what, cmd)?
    Ok(())
}

// Values written into line-based config files must stay on one line.
fn one_line(key: string, v: string) -> Result[unit, string] {
    if v.contains("\n") || v.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    Ok(())
}

fn has_space(v: string) -> bool { v.contains(" ") || v.contains("\t") }

// PID 1 is systemd: the only case where timedatectl and hostnamectl work.
fn systemd_running() -> bool { fs::is_dir("/run/systemd/system") }

fn on_path(cmd: string) -> bool {
    if let Ok(out) = shell::bash("command -v " + q(cmd), Value::Null) { out.success } else { false }
}

// Give `to` the owner, group and mode of `from`.
fn copy_owner_mode(from: string, to: string) -> Result[unit, string] {
    let md = fs::metadata(from)?
    let uid = md.get("uid").unwrap_or(Value::Null)
    let gid = md.get("gid").unwrap_or(Value::Null)
    fs::chown(to, uid, gid)?
    fs::chmod(to, md.get("mode").unwrap_or(Value::Int(0)))
}

// Replace a config file atomically: write a temp file beside it, give it
// the old file's owner and mode, and rename it into place, so a crash or
// full disk never leaves a half-written /etc/fstab.
fn write_atomic(p: string, text: string) -> Result[unit, string] {
    let tmp = path::join(path::parent(p), "." + path::filename(p) + ".cw-tmp")
    fs::write(tmp, text)?
    if fs::is_file(p) {
        if let Err(e) = copy_owner_mode(p, tmp) {
            fs::delete(tmp).unwrap_or(())
            return Err(e)
        }
    }
    if let Err(e) = fs::move(tmp, p) {
        fs::delete(tmp).unwrap_or(())
        return Err(e)
    }
    Ok(())
}
