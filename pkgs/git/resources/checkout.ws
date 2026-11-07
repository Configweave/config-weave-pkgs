use value
use fs
use log
use checkout

// A git working tree at `dest`, cloned from `repo` and held at `ref`.
//
// check never writes: it reads the local checkout and asks the remote
// what `ref` points to now (git ls-remote), so a branch that moved on the
// remote is drift even though the directory already exists. Every case
// apply would refuse (a wrong origin, a non-repo destination, local
// changes without force) is an error from check too. The decision lives
// in checkout::plan so the two can never disagree.
fn check(params: Value) -> Result[CheckResult, string] {
    let p = checkout::plan(params)?
    if p.get(0).unwrap_or("") == "converged" { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = checkout::plan(params)?
    let action = p.get(0).unwrap_or("")
    if action == "converged" { return Ok(ApplyResult::Success) }
    let dest = checkout::dest_param(params)?
    if action == "remove" {
        // plan has already proven this is the top of a git work tree,
        // not a symlink, not / or a top-level directory, and clean unless
        // force is set. The source repository is never touched.
        log::info("removing checkout " + dest)
        fs::delete_dir(dest)?
        return Ok(ApplyResult::Success)
    }
    let repo = checkout::repo_param(params)?
    let kind = p.get(1).unwrap_or("")
    let name = p.get(2).unwrap_or("")
    let sha = p.get(3).unwrap_or("")
    let depth = checkout::param_int(params, "depth", 0)
    let shown = if kind == "commit" { sha } else { kind + " " + name }
    if action == "clone" {
        log::info("cloning " + checkout::redact(repo) + " into " + dest + " at " + shown)
        checkout::clone(dest, repo, kind, name, sha, depth)?
        return Ok(ApplyResult::Success)
    }
    log::info("updating " + dest + " to " + shown)
    checkout::update(dest, repo, kind, name, sha, 0, checkout::param_bool(params, "force", false))?
    Ok(ApplyResult::Success)
}
