use value
use fs
use path
use shell

// Working-copy helpers for subversion.checkout, modelled on the safety
// rules of git.checkout (pkgs/git/lib/worktree.ws) but sharing no code
// with it.
//
// Every svn call goes through bash with the inputs in environment
// variables ("$CW_DEST", "$CW_REPO", ...), never spliced into the script
// text, so no input is ever parsed by the shell. Every svn call has
// --non-interactive (no prompt, no certificate trust) and every call that
// can walk a tree has --ignore-externals, so no hidden second repository
// is read or changed. dest is absolute and repo starts with a URL scheme,
// so svn never reads either as an option, and neither may contain '@', so
// svn never reads part of one as a peg revision.

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

fn has_control(s: string) -> bool {
    s.chars().any(|c| c < ' ') || s.contains("\u{7f}")
}

// ---------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------

// An absolute path without '..' segments, control characters or '@',
// returned normalized (no trailing slash, no '.' segments).
fn dest_param(params: Value) -> Result[string, string] {
    let d = param_str(params, "dest", "")
    if d == "" { return Err("missing 'dest' parameter") }
    if !d.starts_with("/") { return Err("'dest' must be an absolute path: " + d) }
    if has_control(d) { return Err("'dest' must not contain control characters or line breaks") }
    if d.contains("@") { return Err("'dest' must not contain '@' (svn reads it as a peg revision): " + d) }
    for seg in d.split("/") {
        if seg == ".." { return Err("'dest' must not contain '..' segments: " + d) }
    }
    Ok(path::normalize(d))
}

// `/` and every top-level directory are never removed, whatever the
// playbook says, and neither is anything that is not a recognized
// working copy (see inspect).
fn refuse_critical(d: string) -> Result[unit, string] {
    let segs = d.split("/").filter(|s| s != "")
    if segs.len() <= 1 {
        return Err("refusing to remove '" + d + "': 'dest' is / or a top-level directory")
    }
    Ok(())
}

// The userinfo of a URL (scheme://userinfo@host/...), or "" when there is
// none.
fn userinfo(r: string) -> string {
    let i = r.find("://").unwrap_or(-1)
    if i < 0 { return "" }
    let rest = r.slice(i + 3, r.len())
    let end = rest.find("/").unwrap_or(rest.len())
    let authority = rest.slice(0, end)
    let at = authority.find("@").unwrap_or(-1)
    if at < 0 { return "" }
    authority.slice(0, at)
}

// The URL with any userinfo replaced by ***, for every diagnostic.
fn redact(r: string) -> string {
    let u = userinfo(r)
    if u == "" { return r }
    r.replace(u + "@", "***@")
}

// A repository URL with one of svn's own schemes. svn+ssh://user@host is
// a user name, not a secret, and stays allowed; a password, or any user
// part on http(s) (where the "user" is usually a token), is rejected.
// '@' is allowed only in that user part.
fn repo_param(params: Value) -> Result[string, string] {
    let r = param_str(params, "repo", "")
    if r == "" { return Err("missing 'repo' parameter (required when ensure = :present)") }
    if has_control(r) { return Err("'repo' must not contain control characters or line breaks") }
    let l = r.to_lower()
    let schemes = ["file://", "http://", "https://", "svn://", "svn+ssh://"]
    if !schemes.any(|s| l.starts_with(s)) {
        return Err("'repo' must be a file://, http://, https://, svn:// or svn+ssh:// URL: " + redact(r))
    }
    let u = userinfo(r)
    if u.contains(":") || ((l.starts_with("http://") || l.starts_with("https://")) && u != "") {
        return Err("'repo' must not embed credentials (" + redact(r) + "); use an ssh key or a credential store set up separately")
    }
    let rest = if u == "" { r } else { r.replace(u + "@", "") }
    if rest.contains("@") { return Err("'repo' must not contain '@' outside the user part (svn reads it as a peg revision): " + redact(r)) }
    Ok(r)
}

// "" (follow the repository's HEAD) or a positive revision number,
// written without leading zeros so it compares as text with svn's output.
fn revision_param(params: Value) -> Result[string, string] {
    let r = param_str(params, "revision", "")
    if r == "" { return Ok(r) }
    let digits = r.chars().all(|c| c >= '0' && c <= '9')
    if !digits || r.starts_with("0") || r.len() > 10 {
        return Err("invalid 'revision' '" + r + "': expected \"\" (HEAD) or a positive revision number without leading zeros")
    }
    Ok(r)
}

// ---------------------------------------------------------------------
// Running svn
// ---------------------------------------------------------------------

// C-locale messages, so the parsers below read stable English labels.
fn run(script: string, vars: Map[string, Value]) -> Result[CmdOutput, string] {
    vars.insert("LC_ALL", Value::String("C"))
    shell::bash(script, Value::Map(#{ "env": Value::Map(vars) }))
}

fn in_dest(dest: string, script: string) -> Result[CmdOutput, string] {
    run(script, #{ "CW_DEST": Value::String(dest) })
}

// A failed command's error: stderr, else stdout, with the exit code. The
// repo URL is redacted wherever svn repeats it.
fn cmd_err(what: string, out: CmdOutput, repo: string) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    if repo != "" { text = text.replace(repo, redact(repo)) }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

// The value of a "Label: value" line of `svn info`, or "".
fn info_field(text: string, label: string) -> string {
    for line in text.split("\n") {
        if line.starts_with(label + ": ") { return line.slice(label.len() + 2, line.len()).trim() }
    }
    ""
}

// ---------------------------------------------------------------------
// Desired state: what the repository says now
// ---------------------------------------------------------------------

// [canonical URL, revision] of `repo` at `rev` ("" = HEAD), asked from
// the repository itself, which reads nothing local, so check stays
// read-only and still sees a new HEAD. The canonical URL is the form svn
// records in a working copy (percent-encoded, no trailing slash). A
// repository that cannot be read, a revision it does not have, or a path
// that is not a directory at that revision is an error, never drift.
fn remote(repo: string, rev: string) -> Result[List[string], string] {
    let r = if rev == "" { "HEAD" } else { rev }
    let out = run("svn info --non-interactive -r \"$CW_REV\" -- \"$CW_REPO\"", #{ "CW_REPO": Value::String(repo), "CW_REV": Value::String(r) })?
    if !out.success { return Err(cmd_err("svn info " + redact(repo) + " at " + r, out, repo)) }
    let url = info_field(out.stdout, "URL")
    let got = info_field(out.stdout, "Revision")
    let kind = info_field(out.stdout, "Node Kind")
    if url == "" || got == "" { return Err("svn info " + redact(repo) + " printed no URL or revision") }
    if kind != "directory" { return Err(redact(repo) + " is not a directory at revision " + got + " (node kind '" + kind + "')") }
    Ok([url, got])
}

// ---------------------------------------------------------------------
// Local state
// ---------------------------------------------------------------------

// [state, url]. state is "missing", "symlink", "file" (anything that is
// not a directory), "empty" (an empty directory), "foreign" (a directory
// that is not the root of a working copy with its own .svn directory) or
// "checkout"; url is the working copy's URL for "checkout", else "".
fn inspect(dest: string) -> Result[List[string], string] {
    if !fs::lexists(dest) { return Ok(["missing", ""]) }
    if fs::read_link(dest).is_ok() { return Ok(["symlink", ""]) }
    if !fs::is_dir(dest) { return Ok(["file", ""]) }
    if fs::list_dir(dest)?.is_empty() { return Ok(["empty", ""]) }
    let adm = path::join(dest, ".svn")
    if fs::read_link(adm).is_ok() || !fs::is_dir(adm) { return Ok(["foreign", ""]) }
    let out = in_dest(dest, "cd -- \"$CW_DEST\" && svn info --non-interactive -- \"$(pwd -P)\" && echo \"CW-Physical: $(pwd -P)\"")?
    if !out.success {
        // Not a working copy at all: not ours. Anything else (a missing
        // svn, a working copy that needs `svn upgrade` or `svn cleanup`)
        // is an error.
        if out.stderr.contains("155007") { return Ok(["foreign", ""]) }
        return Err(cmd_err("svn info " + dest, out, ""))
    }
    // The root of the working copy must be dest itself, not a parent
    // working copy that dest happens to sit inside.
    let root = info_field(out.stdout, "Working Copy Root Path")
    let phys = info_field(out.stdout, "CW-Physical")
    if root == "" || root != phys { return Ok(["foreign", ""]) }
    let url = info_field(out.stdout, "URL")
    if url == "" { return Err("svn info " + dest + " printed no URL") }
    Ok(["checkout", url])
}

// [low, high, flags] from svnversion: the lowest and highest working
// revision in the whole working copy (equal unless revisions are mixed)
// and its flags (M modified, S switched, P sparse). Read locally only.
fn revisions(dest: string) -> Result[List[string], string] {
    let out = in_dest(dest, "svnversion \"$CW_DEST\"")?
    if !out.success { return Err(cmd_err("svnversion " + dest, out, "")) }
    let v = out.stdout.trim()
    let flags = ""
    let nums = v
    while nums != "" {
        let last = nums.slice(nums.len() - 1, nums.len())
        if last != "M" && last != "S" && last != "P" { break }
        flags = last + flags
        nums = nums.slice(0, nums.len() - 1)
    }
    let parts = nums.split(":")
    let ok = parts.len() >= 1 && parts.len() <= 2 && parts.all(|p| p != "" && p.chars().all(|c| c >= '0' && c <= '9'))
    if !ok { return Err("svnversion " + dest + " reported '" + v + "', not a working copy revision") }
    let low = parts.get(0).unwrap_or("")
    let high = parts.get(parts.len() - 1).unwrap_or("")
    Ok([low, high, flags])
}

// The lines of `svn status` that are local state: edits, additions,
// deletions, missing or obstructed items, conflicts, switched or locked
// paths, and unversioned items. Ignored items count only when asked (a
// removal would delete them, an update leaves them alone). "X" lines only
// name an external definition and are not local state.
fn changes(dest: string, ignored: bool) -> Result[List[string], string] {
    let flag = if ignored { " --no-ignore" } else { "" }
    let out = in_dest(dest, "svn status --non-interactive --ignore-externals" + flag + " -- \"$CW_DEST\"")?
    if !out.success { return Err(cmd_err("svn status " + dest, out, "")) }
    Ok(out.stdout.split("\n").filter(|l| l.trim() != "" && !l.starts_with("X ")))
}

// A working copy inside dest other than dest itself: an external or a
// nested checkout. svn status with --ignore-externals does not look into
// those, so a removal would delete them unseen.
fn nested_wc(dest: string) -> Result[string, string] {
    let out = in_dest(dest, "find \"$CW_DEST\" -mindepth 2 -name .svn -print -quit")?
    if !out.success { return Err(cmd_err("find in " + dest, out, "")) }
    Ok(out.stdout.trim())
}

// Refuse to change a working copy that holds local state, naming the
// first few paths.
fn refuse_changes(dest: string, what: string, ignored: bool) -> Result[unit, string] {
    let c = changes(dest, ignored)?
    if c.is_empty() { return Ok(()) }
    let shown: List[string] = []
    for l in c {
        if shown.len() < 5 { shown.push(l.trim()) }
    }
    Err("refusing to " + what + " '" + dest + "': it has local edits, unversioned, switched or locked paths (" + shown.join("; ") + ")")
}

// ---------------------------------------------------------------------
// Plan: one decision shared by check and apply
// ---------------------------------------------------------------------

// [action, revision]. action is "converged", "checkout", "update" or
// "remove"; revision is the number to check out or update to (empty for
// removal). Every refusal is an Err here, so check reports it before
// apply runs, and check never changes anything.
fn plan(params: Value) -> Result[List[string], string] {
    let dest = dest_param(params)?
    let rev = revision_param(params)?
    if !want_present(params)? {
        refuse_critical(dest)?
        let repo = param_str(params, "repo", "")
        if repo != "" { repo = repo_param(params)? }
        let st = inspect(dest)?
        let state = st.get(0).unwrap_or("")
        if state == "missing" { return Ok(["converged", ""]) }
        if state == "symlink" { return Err("refusing to remove '" + dest + "': it is a symlink, not a working copy") }
        if state != "checkout" { return Err("refusing to remove '" + dest + "': it is not the root of a Subversion working copy") }
        if repo != "" {
            let want = remote(repo, "")?.get(0).unwrap_or("")
            let have = st.get(1).unwrap_or("")
            if have != want { return Err("refusing to remove '" + dest + "': it is a working copy of " + redact(have) + ", not " + redact(want)) }
        }
        let flags = revisions(dest)?.get(2).unwrap_or("")
        if flags.contains("S") { return Err("refusing to remove '" + dest + "': it has switched paths") }
        refuse_changes(dest, "remove", true)?
        let inner = nested_wc(dest)?
        if inner != "" { return Err("refusing to remove '" + dest + "': it holds another working copy (" + inner + "), an external or a nested checkout") }
        return Ok(["remove", ""])
    }
    let repo = repo_param(params)?
    let st = inspect(dest)?
    let state = st.get(0).unwrap_or("")
    if state == "symlink" { return Err("'dest' " + dest + " is a symlink; point dest at a real path") }
    if state == "file" { return Err("'dest' " + dest + " exists and is not a directory") }
    if state == "empty" { return Err("'dest' " + dest + " is an existing empty directory, not a working copy; refusing to check out into it (remove it, or let the resource create dest)") }
    if state == "foreign" { return Err("'dest' " + dest + " is a directory that is not the root of a Subversion working copy; refusing to overwrite it") }
    let r = remote(repo, rev)?
    let want_url = r.get(0).unwrap_or("")
    let want_rev = r.get(1).unwrap_or("")
    if state == "missing" { return Ok(["checkout", want_rev]) }
    let have_url = st.get(1).unwrap_or("")
    if have_url != want_url { return Err("'dest' " + dest + " is a working copy of " + redact(have_url) + ", not " + redact(want_url) + "; refusing to change it") }
    let v = revisions(dest)?
    let low = v.get(0).unwrap_or("")
    let high = v.get(1).unwrap_or("")
    let flags = v.get(2).unwrap_or("")
    // Converged only when every path of the working copy is at the wanted
    // revision and nothing is switched; local edits alone do not make a
    // working copy at the right revision drift.
    if low == want_rev && high == want_rev && !flags.contains("S") { return Ok(["converged", want_rev]) }
    if flags.contains("S") { return Err("refusing to update '" + dest + "': it has switched paths") }
    refuse_changes(dest, "update", false)?
    Ok(["update", want_rev])
}

// ---------------------------------------------------------------------
// Apply
// ---------------------------------------------------------------------

fn svn(repo: string, what: string, script: string, vars: Map[string, Value]) -> Result[unit, string] {
    let out = run(script, vars)?
    if out.success { return Ok(()) }
    Err(cmd_err(what, out, repo))
}

// After an apply, the whole working copy must be at `rev`.
fn confirm(dest: string, rev: string) -> Result[unit, string] {
    let v = revisions(dest)?
    let low = v.get(0).unwrap_or("")
    let high = v.get(1).unwrap_or("")
    if low != rev || high != rev { return Err("after the update, " + dest + " is at revision " + low + ":" + high + ", expected " + rev) }
    Ok(())
}

// Check out into a scratch sibling of dest, and only then move it onto
// dest. A checkout that fails half way therefore never leaves a half-made
// working copy at dest for the next run to trip over.
fn checkout(dest: string, repo: string, rev: string) -> Result[unit, string] {
    let parent = path::parent(dest)
    if parent != "" && !fs::is_dir(parent) { fs::mkdir(parent)? }
    let scratch = path::join(parent, "." + path::filename(dest) + ".cw-checkout")
    if fs::lexists(scratch) {
        if fs::read_link(scratch).is_ok() || !fs::is_dir(scratch) { return Err("scratch path " + scratch + " exists and is not a directory") }
        fs::delete_dir(scratch)?
    }
    let vars: Map[string, Value] = #{ "CW_REPO": Value::String(repo), "CW_REV": Value::String(rev), "CW_DEST": Value::String(scratch) }
    let made = svn(repo, "svn checkout " + redact(repo) + " at " + rev, "svn checkout -q --non-interactive --ignore-externals -r \"$CW_REV\" -- \"$CW_REPO\" \"$CW_DEST\"", vars)
    if made.is_ok() { made = confirm(scratch, rev) }
    if made.is_err() {
        if fs::is_dir(scratch) { fs::delete_dir(scratch)? }
        return made
    }
    fs::move(scratch, dest)?
    Ok(())
}

// Update the whole working copy, every path, to `rev`, up or down. plan
// has proven it clean, so no conflict can arise from local state.
fn update(dest: string, repo: string, rev: string) -> Result[unit, string] {
    let vars: Map[string, Value] = #{ "CW_REV": Value::String(rev), "CW_DEST": Value::String(dest) }
    svn(repo, "svn update " + dest + " to " + rev, "svn update -q --non-interactive --ignore-externals -r \"$CW_REV\" -- \"$CW_DEST\"", vars)?
    confirm(dest, rev)
}
