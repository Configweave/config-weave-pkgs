use value
use fs
use log
use wc

// A Subversion working copy at `dest`, checked out from `repo` and held
// at `revision` ("" follows the repository's HEAD).
//
// check never writes: it reads the working copy locally (svn info,
// svnversion, svn status) and asks the repository for the wanted URL and
// revision, so a new HEAD is drift even though the working copy exists.
// Every case apply would refuse (another URL, a directory that is not a
// working copy, local state before an update or removal) is an error
// from check too. The decision lives in wc::plan so the two can never
// disagree.
fn check(params: Value) -> Result[CheckResult, string] {
    let p = wc::plan(params)?
    if p.get(0).unwrap_or("") == "converged" { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = wc::plan(params)?
    let action = p.get(0).unwrap_or("")
    if action == "converged" { return Ok(ApplyResult::Success) }
    let dest = wc::dest_param(params)?
    if action == "remove" {
        // plan has already proven this is the root of a clean working
        // copy with no switched paths and no working copy inside it, not
        // a symlink, not / or a top-level directory. The repository is
        // never touched.
        log::info("removing working copy " + dest)
        fs::delete_dir(dest)?
        return Ok(ApplyResult::Success)
    }
    let repo = wc::repo_param(params)?
    let rev = p.get(1).unwrap_or("")
    if action == "checkout" {
        log::info("checking out " + wc::redact(repo) + " at revision " + rev + " into " + dest)
        wc::checkout(dest, repo, rev)?
        return Ok(ApplyResult::Success)
    }
    log::info("updating " + dest + " to revision " + rev)
    wc::update(dest, repo, rev)?
    Ok(ApplyResult::Success)
}
