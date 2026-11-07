use value
use fs
use path
use shell

// Helpers for git.checkout. Separate from common.ws on purpose: that file
// is the git-config command builder, and none of its scope/home semantics
// apply to a working tree.
//
// Every git call goes through bash with the inputs in environment
// variables ("$CW_DEST", "$CW_REPO", ...), never spliced into the script
// text, so no input is ever parsed by the shell. Inputs are also validated
// so that git itself never reads one as an option: dest is absolute, and
// repo and ref may not start with '-'.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
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

fn has_control(s: string) -> bool {
    s.chars().any(|c| c < ' ') || s.contains("\u{7f}")
}

// ---------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------

// An absolute path without '..' segments or control characters, returned
// normalized (no trailing slash, no '.' segments).
fn dest_param(params: Value) -> Result[string, string] {
    let d = param_str(params, "dest", "")
    if d == "" { return Err("missing 'dest' parameter") }
    if !d.starts_with("/") { return Err("'dest' must be an absolute path: " + d) }
    if has_control(d) { return Err("'dest' must not contain control characters or line breaks") }
    for seg in d.split("/") {
        if seg == ".." { return Err("'dest' must not contain '..' segments: " + d) }
    }
    Ok(path::normalize(d))
}

// `/` and every top-level directory are never removed, whatever the
// playbook says, and neither is anything that is not a recognized
// checkout (see inspect).
fn refuse_critical(d: string) -> Result[unit, string] {
    let segs = d.split("/").filter(|s| s != "")
    if segs.len() <= 1 {
        return Err("refusing to remove '" + d + "': 'dest' is / or a top-level directory")
    }
    Ok(())
}

// The userinfo of a URL with an authority (scheme://userinfo@host/...),
// or "" when there is none.
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

// Credentials do not belong in the URL: git stores the URL in
// .git/config and repeats it in its messages. ssh://git@host is a user
// name, not a secret, and stays allowed; a password, or any userinfo on
// http(s) (where the "user" is usually a token), is rejected.
fn repo_param(params: Value) -> Result[string, string] {
    let r = param_str(params, "repo", "")
    if r == "" { return Err("missing 'repo' parameter (required when ensure = :present)") }
    if has_control(r) { return Err("'repo' must not contain control characters or line breaks") }
    if r.starts_with("-") { return Err("'repo' must not start with '-'") }
    let l = r.to_lower()
    if l.starts_with("ext::") || l.starts_with("fd::") { return Err("'repo' must not use the ext:: or fd:: transport") }
    let u = userinfo(r)
    if u.contains(":") || ((l.starts_with("http://") || l.starts_with("https://")) && u != "") {
        return Err("'repo' must not embed credentials (" + redact(r) + "); use a credential helper or an ssh key")
    }
    Ok(r)
}

// A branch, tag, full refs/heads/ or refs/tags/ name, or a full commit
// id. The character set is a strict subset of what git allows in a ref
// name, so nothing here can be an option, a revision expression
// (~ ^ : @{) or a glob.
fn ref_param(params: Value) -> Result[string, string] {
    let r = param_str(params, "ref", "")
    if r == "" { return Ok(r) }
    let bad = Err("invalid 'ref' '" + r + "': expected a branch, a tag or a full commit id")
    if r.starts_with("-") || r.starts_with("/") || r.ends_with("/") || r.ends_with(".") || r.ends_with(".lock") { return bad }
    if r.contains("..") || r.contains("//") || r.contains("/.") || r.starts_with(".") { return bad }
    let ok = r.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' || c == '/' || c == '+')
    if !ok { return bad }
    Ok(r)
}

fn depth_param(params: Value) -> Result[int, string] {
    let d = param_int(params, "depth", 0)
    if d < 0 { return Err("'depth' must be 0 (full history) or a positive number of commits") }
    Ok(d)
}

// A full SHA-1 (40) or SHA-256 (64) object id. Abbreviated ids are not
// accepted: they cannot be told apart from a branch named "deadbeef".
fn is_sha(r: string) -> bool {
    if r.len() != 40 && r.len() != 64 { return false }
    r.chars().all(|c| (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
}

// ---------------------------------------------------------------------
// Running git
// ---------------------------------------------------------------------

// No prompts (a missing credential fails instead of hanging the run) and
// C-locale messages.
fn run(script: string, vars: Map[string, Value]) -> Result[CmdOutput, string] {
    vars.insert("GIT_TERMINAL_PROMPT", Value::String("0"))
    vars.insert("LC_ALL", Value::String("C"))
    shell::bash(script, Value::Map(#{ "env": Value::Map(vars) }))
}

fn in_dest(dest: string, script: string) -> Result[CmdOutput, string] {
    run(script, #{ "CW_DEST": Value::String(dest) })
}

// A failed command's error: stderr, else stdout, with the exit code. The
// repo URL is redacted wherever git repeats it.
fn cmd_err(what: string, out: CmdOutput, repo: string) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    if repo != "" { text = text.replace(repo, redact(repo)) }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

// ---------------------------------------------------------------------
// Desired state: what the remote says the ref is right now
// ---------------------------------------------------------------------

// [kind, name, sha]: kind is "branch", "tag" or "commit". Asks the remote
// with ls-remote, which reads without touching any local repository, so
// check stays read-only and still sees a branch that moved. A ref the
// remote does not have, or a remote that cannot be reached, is an error,
// never drift.
fn resolve(repo: string, r: string) -> Result[List[string], string] {
    if is_sha(r) { return Ok(["commit", r.to_lower(), r.to_lower()]) }
    let vars: Map[string, Value] = #{ "CW_REPO": Value::String(repo) }
    if r == "" {
        let out = run("git ls-remote --symref -- \"$CW_REPO\" HEAD", vars)?
        if !out.success { return Err(cmd_err("git ls-remote " + redact(repo), out, repo)) }
        let branch = ""
        let sha = ""
        for line in out.stdout.split("\n") {
            let cols = line.split("\t")
            if cols.len() != 2 || cols.get(1).unwrap_or("") != "HEAD" { continue }
            let left = cols.get(0).unwrap_or("")
            if left.starts_with("ref: refs/heads/") { branch = left.slice(16, left.len()) } else { sha = left }
        }
        if branch == "" || sha == "" { return Err("the remote " + redact(repo) + " has no default branch (empty repository?); set 'ref'") }
        return Ok(["branch", branch, sha])
    }
    let out = run("git ls-remote -- \"$CW_REPO\"", vars)?
    if !out.success { return Err(cmd_err("git ls-remote " + redact(repo), out, repo)) }
    let want_branch = if r.starts_with("refs/tags/") { "" } else if r.starts_with("refs/heads/") { r } else { "refs/heads/" + r }
    let want_tag = if r.starts_with("refs/heads/") { "" } else if r.starts_with("refs/tags/") { r } else { "refs/tags/" + r }
    let branch_sha = ""
    let tag_sha = ""
    let peeled = ""
    for line in out.stdout.split("\n") {
        let cols = line.split("\t")
        if cols.len() != 2 { continue }
        let name = cols.get(1).unwrap_or("")
        let sha = cols.get(0).unwrap_or("")
        if want_branch != "" && name == want_branch { branch_sha = sha }
        if want_tag != "" && name == want_tag { tag_sha = sha }
        if want_tag != "" && name == want_tag + "^{{}}" { peeled = sha }
    }
    if branch_sha != "" && tag_sha != "" {
        return Err("'ref' " + r + " names both a branch and a tag on the remote; write refs/heads/" + r + " or refs/tags/" + r)
    }
    if branch_sha != "" { return Ok(["branch", want_branch.slice(11, want_branch.len()), branch_sha]) }
    // An annotated tag lists the tag object, then the commit it peels to.
    if tag_sha != "" { return Ok(["tag", want_tag.slice(10, want_tag.len()), if peeled != "" { peeled } else { tag_sha }]) }
    Err("'ref' " + r + " is not a branch or tag of " + redact(repo))
}

// ---------------------------------------------------------------------
// Local state
// ---------------------------------------------------------------------

// What is at dest: "missing", "empty" (an empty directory), "symlink",
// "file" (anything that is not a directory), "foreign" (a non-empty
// directory that is not the top of a git work tree with its own .git
// directory) or "checkout".
fn inspect(dest: string) -> Result[string, string] {
    if !fs::lexists(dest) { return Ok("missing") }
    if fs::read_link(dest).is_ok() { return Ok("symlink") }
    if !fs::is_dir(dest) { return Ok("file") }
    if fs::list_dir(dest)?.is_empty() { return Ok("empty") }
    let gd = path::join(dest, ".git")
    if fs::read_link(gd).is_ok() || !fs::is_dir(gd) { return Ok("foreign") }
    // The top of the work tree must be dest itself, not a parent repo
    // that dest happens to sit inside. Both sides are physical paths.
    let out = in_dest(dest, "cd -- \"$CW_DEST\" && top=$(git rev-parse --show-toplevel) && [ \"$top\" = \"$(pwd -P)\" ]")?
    if out.success { return Ok("checkout") }
    // Not a repository at all, or a nested directory: not ours. Anything
    // else (dubious ownership, a corrupt repository) is an error.
    if out.stderr.trim() == "" || out.stderr.contains("not a git repository") { return Ok("foreign") }
    Err(cmd_err("git rev-parse in " + dest, out, ""))
}

fn origin(dest: string) -> Result[string, string] {
    let out = in_dest(dest, "git -C \"$CW_DEST\" config --get remote.origin.url")?
    if out.code == 1 { return Ok("") }
    if !out.success { return Err(cmd_err("git config remote.origin.url in " + dest, out, "")) }
    Ok(out.stdout.trim())
}

// The commit at `rev`, or "" when it does not resolve (an unborn HEAD, a
// missing ref).
fn rev(dest: string, r: string) -> Result[string, string] {
    let out = run("git -C \"$CW_DEST\" rev-parse -q --verify \"$CW_REV^{{commit}}\"", #{ "CW_DEST": Value::String(dest), "CW_REV": Value::String(r) })?
    if !out.success { return Ok("") }
    Ok(out.stdout.trim())
}

// Local modifications. Untracked files count only when asked: an update
// leaves them in place, a removal would delete them.
fn dirty(dest: string, untracked: bool) -> Result[bool, string] {
    let flag = if untracked { "--untracked-files=normal" } else { "--untracked-files=no" }
    let out = in_dest(dest, "git -C \"$CW_DEST\" status --porcelain " + flag)?
    if !out.success { return Err(cmd_err("git status in " + dest, out, "")) }
    Ok(out.stdout.trim() != "")
}

fn is_ancestor(dest: string, a: string, b: string) -> Result[bool, string] {
    let out = run("git -C \"$CW_DEST\" merge-base --is-ancestor \"$CW_A\" \"$CW_B\"", #{ "CW_DEST": Value::String(dest), "CW_A": Value::String(a), "CW_B": Value::String(b) })?
    Ok(out.success)
}

// ---------------------------------------------------------------------
// Plan: one decision shared by check and apply
// ---------------------------------------------------------------------

// [action, kind, name, sha]. action is "converged", "clone", "update" or
// "remove"; kind/name/sha are the resolved target (empty for removal).
// Every refusal is an Err here, so check reports it before apply runs.
fn plan(params: Value) -> Result[List[string], string] {
    let dest = dest_param(params)?
    let force = param_bool(params, "force", false)
    if !want_present(params)? {
        refuse_critical(dest)?
        let repo = param_str(params, "repo", "")
        if repo != "" { repo = repo_param(params)? }
        let st = inspect(dest)?
        if st == "missing" { return Ok(["converged", "", "", ""]) }
        if st == "symlink" { return Err("refusing to remove '" + dest + "': it is a symlink, not a checkout") }
        if st != "checkout" { return Err("refusing to remove '" + dest + "': it is not a git checkout") }
        if repo != "" {
            let o = origin(dest)?
            if o != repo { return Err("refusing to remove '" + dest + "': its origin is " + redact(o) + ", not " + redact(repo)) }
        }
        if !force && dirty(dest, true)? {
            return Err("refusing to remove '" + dest + "': it has local changes or untracked files; set force = true to discard them")
        }
        return Ok(["remove", "", "", ""])
    }
    let repo = repo_param(params)?
    let r = ref_param(params)?
    depth_param(params)?
    let st = inspect(dest)?
    if st == "symlink" { return Err("'dest' " + dest + " is a symlink; point dest at a real directory") }
    if st == "file" { return Err("'dest' " + dest + " exists and is not a directory") }
    if st == "foreign" { return Err("'dest' " + dest + " is a non-empty directory that is not a git checkout; refusing to overwrite it") }
    if st == "checkout" {
        let o = origin(dest)?
        if o != repo { return Err("'dest' " + dest + " is a checkout of " + redact(o) + ", not " + redact(repo) + "; refusing to change it") }
    }
    let t = resolve(repo, r)?
    let kind = t.get(0).unwrap_or("")
    let name = t.get(1).unwrap_or("")
    let sha = t.get(2).unwrap_or("")
    if st == "missing" || st == "empty" { return Ok(["clone", kind, name, sha]) }
    let head = rev(dest, "HEAD")?
    let changed = dirty(dest, false)?
    if head == sha {
        if force && changed { return Ok(["update", kind, name, sha]) }
        return Ok(["converged", kind, name, sha])
    }
    if changed && !force {
        return Err("'dest' " + dest + " has local changes and is not at " + sha + "; set force = true to discard them")
    }
    Ok(["update", kind, name, sha])
}

// ---------------------------------------------------------------------
// Apply
// ---------------------------------------------------------------------

fn git_in(dest: string, repo: string, what: string, script: string, vars: Map[string, Value]) -> Result[unit, string] {
    vars.insert("CW_DEST", Value::String(dest))
    let out = run(script, vars)?
    if out.success { return Ok(()) }
    Err(cmd_err(what, out, repo))
}

// Clone without a checkout into a scratch sibling of dest, check out the
// target the same way as an update, and only then move it onto dest. A
// clone that fails half way therefore never leaves a half-made checkout
// at dest for the next run to trip over. --depth applies only here: depth
// is a clone-time setting and never shrinks an existing clone.
fn clone(dest: string, repo: string, kind: string, name: string, sha: string, depth: int) -> Result[unit, string] {
    let parent = path::parent(dest)
    if parent != "" && !fs::is_dir(parent) { fs::mkdir(parent)? }
    let scratch = path::join(parent, "." + path::filename(dest) + ".cw-clone")
    if fs::lexists(scratch) {
        if fs::read_link(scratch).is_ok() || !fs::is_dir(scratch) { return Err("scratch path " + scratch + " exists and is not a directory") }
        fs::delete_dir(scratch)?
    }
    let opts = "--no-checkout"
    if depth > 0 { opts = opts + " --depth " + str(depth) }
    if kind == "branch" || kind == "tag" { opts = opts + " --branch \"$CW_NAME\"" }
    let vars: Map[string, Value] = #{ "CW_REPO": Value::String(repo), "CW_NAME": Value::String(name) }
    let made = git_in(scratch, repo, "git clone " + redact(repo), "git clone -q " + opts + " -- \"$CW_REPO\" \"$CW_DEST\"", vars)
    // A --no-checkout clone has an empty index, so everything reads as
    // deleted: the first checkout is always forced.
    if made.is_ok() { made = update(scratch, repo, kind, name, sha, depth, true) }
    if made.is_err() {
        if fs::is_dir(scratch) { fs::delete_dir(scratch)? }
        return made
    }
    // dest is missing or an empty directory (plan checked).
    if fs::is_dir(dest) { fs::delete_dir(dest)? }
    fs::move(scratch, dest)?
    Ok(())
}

// Fetch the target and move HEAD to it. A branch is checked out as a
// local branch of the same name; a tag or commit as a detached HEAD.
// Without force, a local branch holding commits that the new tip does not
// contain is never reset.
fn update(dest: string, repo: string, kind: string, name: string, sha: string, depth: int, force: bool) -> Result[unit, string] {
    let dflag = if depth > 0 { " --depth " + str(depth) } else { "" }
    let fflag = if force { " -f" } else { "" }
    let vars: Map[string, Value] = #{ "CW_NAME": Value::String(name), "CW_SHA": Value::String(sha) }
    let target = ""
    if kind == "branch" {
        git_in(dest, repo, "git fetch " + name, "git -C \"$CW_DEST\" fetch -q" + dflag + " origin \"+refs/heads/$CW_NAME:refs/remotes/origin/$CW_NAME\"", vars.clone())?
        target = rev(dest, "refs/remotes/origin/" + name)?
        if target == "" { return Err("branch " + name + " was fetched but does not resolve to a commit") }
        if !force {
            let local = rev(dest, "refs/heads/" + name)?
            if local != "" && !is_ancestor(dest, local, target)? {
                return Err("local branch " + name + " in " + dest + " has commits that are not on the remote; set force = true to reset it")
            }
        }
        git_in(dest, repo, "git checkout " + name, "git -C \"$CW_DEST\" checkout -q" + fflag + " -B \"$CW_NAME\" \"refs/remotes/origin/$CW_NAME\"", vars.clone())?
    } else if kind == "tag" {
        git_in(dest, repo, "git fetch tag " + name, "git -C \"$CW_DEST\" fetch -q" + dflag + " origin \"+refs/tags/$CW_NAME:refs/tags/$CW_NAME\"", vars.clone())?
        target = rev(dest, "refs/tags/" + name)?
        if target == "" { return Err("tag " + name + " was fetched but does not resolve to a commit") }
        vars.insert("CW_SHA", Value::String(target))
        git_in(dest, repo, "git checkout tag " + name, "git -C \"$CW_DEST\" checkout -q" + fflag + " --detach \"$CW_SHA\"", vars.clone())?
    } else {
        if rev(dest, sha)? == "" {
            // By id first (protocol v2 servers allow it), then every branch
            // and tag in case the server only serves advertised tips.
            let byid = run("git -C \"$CW_DEST\" fetch -q" + dflag + " origin \"$CW_SHA\"", #{ "CW_DEST": Value::String(dest), "CW_SHA": Value::String(sha) })?
            if !byid.success || rev(dest, sha)? == "" {
                git_in(dest, repo, "git fetch", "git -C \"$CW_DEST\" fetch -q origin \"+refs/heads/*:refs/remotes/origin/*\" \"+refs/tags/*:refs/tags/*\"", vars.clone())?
            }
        }
        target = rev(dest, sha)?
        if target == "" { return Err("commit " + sha + " is not available from " + redact(repo) + " (or not within a shallow clone's history)") }
        git_in(dest, repo, "git checkout " + sha, "git -C \"$CW_DEST\" checkout -q" + fflag + " --detach \"$CW_SHA\"", vars.clone())?
    }
    let head = rev(dest, "HEAD")?
    if head != target { return Err("after checkout, HEAD of " + dest + " is " + head + ", expected " + target) }
    Ok(())
}
