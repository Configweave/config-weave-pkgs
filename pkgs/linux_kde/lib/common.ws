use value
use env
use fs
use shell

// Helpers shared by linux_kde's resources and gatherers. Imported with
// `use common`; nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

// A failed command's error: stderr, else stdout, always with the exit code.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

fn output(what: string, cmd: string) -> Result[string, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(out.stdout.trim())
}

// The target home: the `home` param, else the account the engine runs as,
// looked up in the passwd database. $HOME is only the last resort, because
// agents and service managers often run with HOME=/.
fn home(params: Value) -> string {
    let h = param_str(params, "home", "")
    if h != "" { return h }
    if let Ok(out) = shell::bash("getent passwd \"$(id -u)\" | cut -d: -f6", Value::Null) {
        if out.success && out.stdout.trim() != "" { return out.stdout.trim() }
    }
    env::home_dir()
}

fn on_path(cmd: string) -> bool {
    if let Ok(out) = shell::bash("command -v " + q(cmd) + " >/dev/null 2>&1", Value::Null) { out.success } else { false }
}

// "uid:gid" of a path, following symlinks.
fn owner(p: string) -> Result[string, string] {
    output("reading the owner of " + p, "stat -L -c '%u:%g' -- " + q(p))
}

// "uid:gid" of a path itself: a symlink's own owner, not its target's,
// which is what chown_ids changes. fs::metadata does not follow a final
// symlink.
fn link_owner(p: string) -> Result[string, string] {
    let md = fs::metadata(p)?
    let uid = md.get("uid").unwrap_or(Value::Null).as_int()
    let gid = md.get("gid").unwrap_or(Value::Null).as_int()
    if uid.is_none() || gid.is_none() { return Err("cannot read the owner of " + p) }
    Ok(str(uid.unwrap_or(0)) + ":" + str(gid.unwrap_or(0)))
}

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

// Whether `p` is a regular file, for a file in a user's tree that this reads
// and rewrites as root. A missing path is false. A symlink as the final
// component, dangling or not, is an Err: following it would read whatever
// the user pointed it at, and the write side refuses it too, so apply could
// never fix it. fs::metadata does not follow a final symlink.
fn user_file(p: string) -> Result[bool, string] {
    if !fs::lexists(p) { return Ok(false) }
    let md = fs::metadata(p)?
    if md.get("is_symlink").unwrap_or(Value::Bool(false)).as_bool().unwrap_or(false) {
        return Err(p + " is a symlink; config-weave runs as root and will not follow a symlink in a user's tree (replace it with a regular file or remove it)")
    }
    Ok(md.get("is_file").unwrap_or(Value::Bool(false)).as_bool().unwrap_or(false))
}

// The contents of a user file, "" when it is missing, never through a final
// symlink: user_file refuses one up front with a clear message, and
// read_with's O_NOFOLLOW catches a link planted between the two calls.
fn read_user_file(p: string) -> Result[string, string] {
    if !user_file(p)? { return Ok("") }
    fs::read_with(p, Value::Map(#{ "follow_symlinks": Value::Bool(false) }))
}
