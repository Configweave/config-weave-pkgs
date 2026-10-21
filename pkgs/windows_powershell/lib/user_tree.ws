// Reading and writing a file in a user's tree — a current-user profile or
// powershell.config.json — from an agent that runs as SYSTEM or root.
//
// A link the user planted would point the read or the write at a file they
// cannot touch themselves, so a symlink at the file, or a symlink or
// directory junction on any directory between the user's profile root and
// the file, is an error naming it. Missing files and directories are fine:
// a missing file reads as absent and a write creates what is missing.
//
// fs::metadata does not follow a final link, and its is_symlink is Rust's
// FileType::is_symlink, which on Windows is any name-surrogate reparse
// point: symbolic links and directory junctions (mount points) alike. A
// reparse point that is not a name surrogate (a OneDrive placeholder, a
// deduplicated file) does not redirect the path and is not reported; the
// host API exposes no file attributes to see one by.
//
// `root` is Option[string]: None for a file outside any user's tree (an
// all-users file or an explicit `path`), which is read and written exactly
// as before. Some(root) is a user file; when root is "" or the file is not
// under it, only the file itself is checked, since nothing says which of
// its ancestors the user owns.
use value
use fs
use path
use sys
use env

fn no_follow() -> Value { Value::Map(#{ "follow_symlinks": Value::Bool(false) }) }

fn windows() -> bool { sys::family() == "windows" }

// The home a user-scope path is derived from: `home`, or else the home of
// the account config-weave runs as, which is where PowerShell's own
// $PROFILE answer for that account lives.
fn root_of(home: string) -> string {
    if home != "" { return home }
    env::home_dir()
}

fn key(p: string) -> string {
    let n = path::normalize(p)
    if windows() { return n.replace("/", "\\").to_lower() }
    n
}

fn is_link(p: string) -> Result[bool, string] {
    if !fs::lexists(p) { return Ok(false) }
    let md = fs::metadata(p)?
    Ok(md.get("is_symlink").unwrap_or(Value::Bool(false)).as_bool().unwrap_or(false))
}

fn link_kind() -> string { if windows() { "a symlink or directory junction" } else { "a symlink" } }

fn account() -> string { if windows() { "SYSTEM" } else { "root" } }

// The directories strictly between `root` and `file`, outermost first. Empty
// when `root` is "" or does not contain `file`.
fn between(root: string, file: string) -> List[string] {
    let none: List[string] = []
    if root == "" { return none }
    let stop = key(root)
    let up: List[string] = []
    let d = path::parent(file)
    let reached = false
    while d != "" {
        if key(d) == stop {
            reached = true
            break
        }
        up.push(d)
        let next = path::parent(d)
        if next == d { break }
        d = next
    }
    if !reached { return none }
    let out: List[string] = []
    let i = up.len()
    while i > 0 {
        i = i - 1
        out.push(up.get(i).unwrap_or(""))
    }
    out
}

// Err when `file`, or a directory between `root` and it, is a link. Run it
// before every read, mkdir and write of a user file: mkdir would otherwise
// create directories through a junction, and the write follow it.
fn guard(root: Option[string], file: string) -> Result[unit, string] {
    if root.is_none() { return Ok(()) }
    for dir in between(root.unwrap_or(""), file) {
        if is_link(dir)? {
            return Err(dir + " is " + link_kind() + "; config-weave runs as " + account() + " and will not follow a link in a user's tree to reach " + file + " (replace it with a real directory or remove it)")
        }
    }
    if is_link(file)? {
        return Err(file + " is " + link_kind() + "; config-weave runs as " + account() + " and will not follow a link in a user's tree (replace it with a regular file or remove it)")
    }
    Ok(())
}

// The file's text, or None when it does not exist or is not a file. An
// unreadable file (not UTF-8) is an Err the caller decides about — so a
// caller that treats a read Err as drift must call guard first, to keep a
// link an error. read_with refuses a final link planted after the guard
// (Unix: O_NOFOLLOW; Windows: check then open, not atomic).
fn read(root: Option[string], file: string) -> Result[Option[string], string] {
    if root.is_none() {
        if !fs::is_file(file) { return Ok(None) }
        return Ok(Some(fs::read(file)?))
    }
    guard(root, file)?
    if !fs::is_file(file) { return Ok(None) }
    Ok(Some(fs::read_with(file, no_follow())?))
}

// Replace the file's contents, creating missing parent directories. For a
// user file the tree is checked before the mkdir and again before the
// write, and the write refuses a final link. Not atomic on Windows, where
// write_with checks and then opens: a link swapped in between those two
// steps is followed. That residual race is accepted.
fn write(root: Option[string], file: string, text: string) -> Result[unit, string] {
    let parent = path::parent(file)
    if root.is_none() {
        if parent != "" { fs::mkdir(parent)? }
        return fs::write(file, text)
    }
    guard(root, file)?
    if parent != "" { fs::mkdir(parent)? }
    guard(root, file)?
    fs::write_with(file, text, no_follow())
}

// Whether the file exists, for a resource that deletes it. A link is an
// error for a user file, even though deleting it would remove only the link.
fn exists(root: Option[string], file: string) -> Result[bool, string] {
    guard(root, file)?
    Ok(fs::exists(file))
}

fn delete(root: Option[string], file: string) -> Result[unit, string] {
    guard(root, file)?
    if fs::exists(file) { fs::delete(file)? }
    Ok(())
}
