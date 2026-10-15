use value
use fs
use path
use shell

// Helpers shared by linux_ssh's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
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

// A failed command's error: stderr, else stdout, always with the exit code.
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

// Values written into line-based config files must stay on one line, or
// they inject a second directive.
fn one_line(key: string, v: string) -> Result[unit, string] {
    if v.contains("\n") || v.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    Ok(())
}

// An account name reaches getent and chown as an operand.
fn valid_user(user: string) -> Result[unit, string] {
    if user == "" { return Err("missing 'user' parameter") }
    if user.starts_with("-") || user.contains(":") || user.contains("/") || user.contains(" ") || user.contains("\t") {
        return Err("invalid user name '" + user + "'")
    }
    one_line("user", user)
}

// A home directory override must be absolute and free of '..'.
fn valid_home(home: string) -> Result[unit, string] {
    one_line("home", home)?
    if !home.starts_with("/") { return Err("'home' must be an absolute path") }
    for seg in home.split("/") { if seg == ".." { return Err("'home' must not contain '..'") } }
    Ok(())
}

// Field `n` (0-based) of the user's passwd entry.
fn passwd_field(user: string, n: int) -> Result[string, string] {
    let out = shell::bash("getent passwd -- " + q(user), Value::Null)?
    if !out.success { return Err("user '" + user + "' does not exist") }
    let fields = out.stdout.trim().split(":")
    if let Some(f) = fields.get(n) { if f != "" { return Ok(f) } }
    Err("cannot read field " + str(n) + " of the passwd entry for '" + user + "'")
}

fn user_home(user: string) -> Result[string, string] { passwd_field(user, 5) }

fn user_uid(user: string) -> Result[string, string] { passwd_field(user, 2) }

fn user_gid(user: string) -> Result[string, string] { passwd_field(user, 3) }

// Hand `p` to `ids` ("uid:gid", as stat prints it). fs::chown does not
// follow a final symlink, so a link planted in a user's tree is never a
// way to hand them some other file.
fn chown_ids(p: string, ids: string) -> Result[unit, string] {
    let f = ids.split(":")
    let uid = f.get(0).unwrap_or("").parse_int()
    let gid = f.get(1).unwrap_or("").parse_int()
    if uid.is_none() || gid.is_none() { return Err("invalid owner '" + ids + "' for " + p) }
    fs::chown(p, Value::Int(uid.unwrap_or(0)), Value::Int(gid.unwrap_or(0)))
}

// The user this process runs as, by passwd entry rather than $HOME (the
// guest agent and many service managers run with HOME=/).
fn current_user() -> Result[string, string] {
    let out = output("id -un", "id -un")?
    Ok(out.stdout.trim())
}

// "<mode> <uid>:<gid>" of a path (octal mode without leading zeros), or ""
// when it does not exist.
fn stat_line(p: string) -> Result[string, string] {
    let out = shell::bash("stat -c '%a %u:%g' -- " + q(p), Value::Null)?
    if !out.success { return Ok("") }
    Ok(out.stdout.trim())
}

// The first whitespace-delimited field of `s` and the rest after it. A
// double-quoted run (authorized_keys options such as command="a b") does not
// end the field; a backslash escapes a quote inside it.
fn split_field(s: string) -> List[string] {
    let n = s.len()
    let i = 0
    let quoted = false
    while i < n {
        let c = s.slice(i, i + 1)
        if quoted && c == "\\" {
            i = i + 2
            continue
        }
        if c == "\"" {
            quoted = !quoted
        } else if !quoted && (c == " " || c == "\t") {
            break
        }
        i = i + 1
    }
    [s.slice(0, i), s.slice(i, n).trim()]
}

fn is_key_type(t: string) -> bool {
    t.starts_with("ssh-") || t.starts_with("ecdsa-sha2-") || t.starts_with("sk-ssh-") || t.starts_with("sk-ecdsa-sha2-")
}

fn is_base64(s: string) -> bool {
    if s.len() < 16 { return false }
    for c in s.chars() {
        let t = str(c)
        if !("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".contains(t)) { return false }
    }
    true
}

// An authorized_keys line as [options, type, blob, comment], or None for a
// blank line, a comment or anything that is not a key.
fn parse_key(line: string) -> Option[List[string]] {
    let s = line.trim()
    if s == "" || s.starts_with("#") { return None }
    let first = split_field(s)
    let opts = ""
    let rest = s
    if !is_key_type(first.get(0).unwrap_or("")) {
        opts = first.get(0).unwrap_or("")
        rest = first.get(1).unwrap_or("")
    }
    let t = split_field(rest)
    let kind = t.get(0).unwrap_or("")
    let b = split_field(t.get(1).unwrap_or(""))
    let blob = b.get(0).unwrap_or("")
    if !is_key_type(kind) || !is_base64(blob) { return None }
    Some([opts, kind, blob, b.get(1).unwrap_or("")])
}

// Replace a file through a temp file beside it and a rename, keeping the
// old file's owner and mode, so a crash never leaves it half-written.
fn write_atomic(p: string, text: string) -> Result[unit, string] {
    let tmp = path::join(path::parent(p), "." + path::filename(p) + ".cw-tmp")
    fs::write(tmp, text)?
    if fs::is_file(p) {
        let keep = "chown -- \"$(stat -c '%u:%g' -- " + q(p) + ")\" " + q(tmp) + " && chmod -- \"$(stat -c '%a' -- " + q(p) + ")\" " + q(tmp)
        if let Err(e) = run("copying owner and mode of " + p, keep) {
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

// Drop-ins sort ahead of distribution and cloud-init ones (50-cloud-init,
// 50-redhat): ssh and sshd both keep the first value they read.
fn dropin_prefix() -> string { "10-config-weave-" }

// An option name becomes part of a file name and the start of a config
// line: letters and digits only, and never a block keyword.
fn valid_option_key(key: string, reserved: List[string]) -> Result[unit, string] {
    if key == "" { return Err("missing 'key' parameter") }
    for c in key.chars() {
        if !("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".contains(str(c))) {
            return Err("'key' must be an option name of letters and digits, got '" + key + "'")
        }
    }
    if reserved.contains(key.to_lower()) { return Err("'" + key + "' opens a block and cannot be set as an option") }
    Ok(())
}

fn shadowed(key: string, p: string) -> string {
    key + " is set by another file that sshd reads before " + p + " (an earlier sshd_config.d drop-in, or sshd_config above its Include line), or sshd_config has no Include for sshd_config.d; sshd -T does not show the wanted value"
}

// Make a running sshd re-read its configuration. Under systemd the unit is
// ssh (Debian, Ubuntu) or sshd (RHEL, Fedora, SUSE, Arch); an inactive unit
// (socket activation before the first connection) needs nothing. Without
// systemd, HUP the listener from its pid file.
fn reload_sshd() -> Result[unit, string] {
    if fs::is_dir("/run/systemd/system") {
        for unit in ["ssh.service", "sshd.service"] {
            if shell::bash("systemctl is-active --quiet " + unit, Value::Null)?.success {
                return run("systemctl reload " + unit, "systemctl reload " + unit)
            }
        }
        return Ok(())
    }
    for pf in ["/run/sshd.pid", "/var/run/sshd.pid"] {
        if fs::is_file(pf) {
            return run("reloading sshd", "pid=$(cat " + q(pf) + ") && if kill -0 \"$pid\" 2>/dev/null; then kill -HUP \"$pid\"; fi")
        }
    }
    Ok(())
}
