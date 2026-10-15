use value
use fs
use path
use shell
use hash
use archive
use log
use common

// The marker records the SHA-256 of the archive that was extracted, so a
// pre-populated dest is still extracted into and a changed src is
// re-extracted.
fn marker(dest: string) -> string { path::join(dest, ".config-weave-archive") }

struct Tree {
    owner: string,
    group: string,
    file_mode: string,
    dir_mode: string,
}

fn tree(params: Value) -> Result[Tree, string] {
    let t = Tree {
        owner: common::param_str(params, "owner", ""),
        group: common::param_str(params, "group", ""),
        file_mode: common::param_str(params, "file_mode", "").trim(),
        dir_mode: common::param_str(params, "dir_mode", "").trim(),
    }
    common::require_principal("owner", t.owner)?
    common::require_principal("group", t.group)?
    if t.file_mode != "" { let bits = common::parse_mode(t.file_mode)? }
    if t.dir_mode != "" { let bits = common::parse_mode(t.dir_mode)? }
    Ok(t)
}

fn sources(params: Value) -> Result[List[string], string] {
    let dest = common::param_str(params, "dest", "")
    common::require_path("dest", dest)?
    if !common::want_present(params)? { return Ok(["", dest]) }
    let src = common::param_str(params, "src", "")
    if src == "" { return Err("missing 'src' parameter (required when ensure is :present)") }
    common::require_path("src", src)?
    Ok([src, dest])
}

// Every entry under dest (dest included) carries the owner, group and
// modes asked for. Symlinks inside the tree are owned like everything else
// but have no mode of their own, so the mode tests skip them.
fn tree_ok(dest: string, t: Tree) -> Result[bool, string] {
    let conds = []
    if t.owner != "" { conds.push("! -user " + common::q(t.owner)) }
    if t.group != "" { conds.push("! -group " + common::q(t.group)) }
    if t.file_mode != "" { conds.push("\\( -type f ! -perm " + common::q(t.file_mode) + " \\)") }
    if t.dir_mode != "" { conds.push("\\( -type d ! -perm " + common::q(t.dir_mode) + " \\)") }
    if conds.is_empty() { return Ok(true) }
    let cmd = "find " + common::q(dest) + " \\( " + conds.join(" -o ") + " \\) -print | head -n 1"
    let out = shell::bash("set -o pipefail; " + cmd, Value::Null)?
    // find fails on an owner it cannot resolve yet: drift, which apply's
    // chown then reports properly
    if !out.success { return Ok(false) }
    Ok(out.stdout.trim() == "")
}

fn apply_tree(dest: string, t: Tree) -> Result[unit, string] {
    if t.owner != "" || t.group != "" {
        common::run("chown " + dest, "chown -R -h -- " + common::q(common::chown_spec(t.owner, t.group)) + " " + common::q(dest))?
    }
    if t.file_mode != "" {
        common::run("chmod files under " + dest, "find " + common::q(dest) + " -type f -exec chmod -- " + common::q(t.file_mode) + " {} +")?
    }
    if t.dir_mode != "" {
        common::run("chmod directories under " + dest, "find " + common::q(dest) + " -type d -exec chmod -- " + common::q(t.dir_mode) + " {} +")?
    }
    Ok(())
}

fn extracted(src: string, dest: string) -> Result[bool, string] {
    if !fs::is_dir(dest) || !fs::is_file(marker(dest)) { return Ok(false) }
    let recorded = fs::read(marker(dest)).unwrap_or("").trim()
    Ok(recorded == hash::sha256_file(src)?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let sd = sources(params)?
    let src = sd[0]
    let dest = sd[1]
    let t = tree(params)?
    if !common::want_present(params)? {
        common::refuse_critical("dest", dest)?
        if fs::lexists(dest) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // A missing archive may be created by an earlier step; apply errors if
    // it is still missing then.
    if !fs::is_file(src) { return Ok(CheckResult::NotConfigured) }
    if !extracted(src, dest)? { return Ok(CheckResult::NotConfigured) }
    if !tree_ok(dest, t)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let sd = sources(params)?
    let src = sd[0]
    let dest = sd[1]
    let t = tree(params)?
    if !common::want_present(params)? {
        common::refuse_critical("dest", dest)?
        if !fs::lexists(dest) { return Ok(ApplyResult::Success) }
        if fs::read_link(dest).is_ok() || !fs::is_dir(dest) { return Err("dest is not a directory: " + dest) }
        log::info("deleting " + dest)
        fs::delete_dir(dest)?
        return Ok(ApplyResult::Success)
    }
    if !fs::is_file(src) { return Err("archive does not exist: " + src) }
    if !extracted(src, dest)? {
        log::info("extracting " + src + " -> " + dest)
        let digest = hash::sha256_file(src)?
        fs::mkdir(dest)?
        archive::extract(src, dest)?
        fs::write(marker(dest), digest + "\n")?
    }
    apply_tree(dest, t)?
    Ok(ApplyResult::Success)
}
