use value
use fs
use path
use shell

// Helpers shared by linux_files' resources and gatherers. Imported with
// `use common`; nothing here is package-external.

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

// A failed command's error: stderr, else stdout (many tools report there),
// always with the exit code.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

fn run(what: string, cmd: string) -> Result[unit, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(())
}

// A path param: absolute, and free of `..` segments so it cannot walk out
// of the tree it names.
fn require_path(key: string, p: string) -> Result[unit, string] {
    if p == "" { return Err("missing '" + key + "' parameter") }
    if !p.starts_with("/") { return Err("'" + key + "' must be an absolute path: " + p) }
    for seg in p.split("/") {
        if seg == ".." { return Err("'" + key + "' must not contain '..' segments: " + p) }
    }
    if p.contains("\n") || p.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    Ok(())
}

// `/` and every top-level directory (`/etc`, `/usr`, `/home`, ...) are never
// deleted recursively, whatever the playbook says.
fn refuse_critical(key: string, p: string) -> Result[unit, string] {
    let n = path::normalize(p)
    let segs = n.split("/").filter(|s| s != "")
    if segs.len() <= 1 {
        return Err("refusing to delete '" + p + "': '" + key + "' is / or a top-level directory")
    }
    Ok(())
}

// Mode as an int, from 3 or 4 octal digits (`644`, `0644`, `2775`).
fn parse_mode(mode: string) -> Result[int, string] {
    let m = mode.trim()
    if m.len() < 3 || m.len() > 4 {
        return Err("invalid mode '" + mode + "' (expected 3 or 4 octal digits such as 0644)")
    }
    let v = 0
    for c in m.chars() {
        if c < '0' || c > '7' {
            return Err("invalid mode '" + mode + "' (expected 3 or 4 octal digits such as 0644)")
        }
        v = v * 8 + (int(c) - int('0'))
    }
    Ok(v)
}

// Same parse for stat's `%a`, which prints octal without a leading zero.
fn octal(s: string) -> int {
    let v = 0
    for c in s.trim().chars() {
        if c < '0' || c > '7' { return -1 }
        v = v * 8 + (int(c) - int('0'))
    }
    v
}

// owner/group may be a name or a numeric id.
fn require_principal(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Ok(()) }
    if v.starts_with("-") || v.contains(":") || v.contains(" ") || v.contains("\n") {
        return Err("invalid '" + key + "' value '" + v + "'")
    }
    Ok(())
}

// The optional mode/owner/group triple most resources take, validated.
struct Attrs {
    mode: string,
    owner: string,
    group: string,
}

fn attrs(params: Value) -> Result[Attrs, string] {
    let a = Attrs {
        mode: param_str(params, "mode", "").trim(),
        owner: param_str(params, "owner", ""),
        group: param_str(params, "group", ""),
    }
    if a.mode != "" { let bits = parse_mode(a.mode)? }
    require_principal("owner", a.owner)?
    require_principal("group", a.group)?
    Ok(a)
}

// stat -L: chmod, chown and writes all follow a symlink at `p`, so the
// comparison must read the same inode they change. An owner or group
// matches either by name or by numeric id, so `owner = "1000"` and an id
// with no passwd entry (which stat names UNKNOWN) both converge.
fn attrs_ok(p: string, a: Attrs) -> Result[bool, string] {
    if a.mode == "" && a.owner == "" && a.group == "" { return Ok(true) }
    let out = shell::bash("stat -L -c '%a %u %U %g %G' -- " + q(p), Value::Null)?
    if !out.success { return Ok(false) }
    let f = out.stdout.trim().split(" ")
    if a.mode != "" && octal(f.get(0).unwrap_or("")) != parse_mode(a.mode)? { return Ok(false) }
    if a.owner != "" && f.get(1).unwrap_or("") != a.owner && f.get(2).unwrap_or("") != a.owner { return Ok(false) }
    if a.group != "" && f.get(3).unwrap_or("") != a.group && f.get(4).unwrap_or("") != a.group { return Ok(false) }
    Ok(true)
}

fn chown_spec(owner: string, group: string) -> string {
    if owner != "" && group != "" { owner + ":" + group } else if owner != "" { owner } else { ":" + group }
}

fn apply_attrs(p: string, a: Attrs) -> Result[unit, string] {
    // chown first: changing ownership clears setuid/setgid bits, which the
    // chmod then puts back.
    if a.owner != "" || a.group != "" {
        run("chown " + p, "chown -- " + q(chown_spec(a.owner, a.group)) + " " + q(p))?
    }
    if a.mode != "" { run("chmod " + p, "chmod -- " + q(a.mode) + " " + q(p))? }
    Ok(())
}

// Whether anything is at `p`, a dangling symlink included (fs::exists
// follows links and reports a dangling one as missing).
fn lexists(p: string) -> bool { fs::read_link(p).is_ok() || fs::exists(p) }

// File content equals `want`. A file that cannot be read as UTF-8 text
// cannot equal a string param, so it is drift rather than an error.
fn content_is(p: string, want: string) -> bool {
    if let Ok(text) = fs::read(p) { text == want } else { false }
}

// A temp file beside `p`: same filesystem, so a rename onto `p` is atomic
// (fs::temp_file lives in /tmp, which is often another filesystem).
fn tmp_sibling(p: string) -> string {
    path::join(path::parent(p), "." + path::filename(p) + ".cw-tmp")
}

// Put a finished temp file in place at `p`. A plain path is replaced by an
// atomic rename, after the temp file takes the old file's owner, group and
// mode (a rename would otherwise reset whatever the playbook does not
// manage). A symlink at `p` is written through, like every other write in
// this package, so the link itself survives.
fn install_tmp(tmp: string, p: string) -> Result[unit, string] {
    if fs::read_link(p).is_ok() {
        let r = fs::copy(tmp, p)
        fs::delete(tmp).unwrap_or(())
        return r
    }
    if fs::is_file(p) {
        // stat -c rather than --reference, which busybox lacks
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
