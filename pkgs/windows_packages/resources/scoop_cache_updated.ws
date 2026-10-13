use value
use env
use path
use common

// The stamp file's mtime records the last refresh this resource performed.
// Scoop is per-user, so the stamp lives under the scoop root it refreshed
// (SCOOP, else ~\scoop) rather than machine-wide.
fn stamp_path() -> string {
    let root = env::get("SCOOP").unwrap_or("")
    if root == "" { root = path::join(env::home_dir(), "scoop") }
    path::join(path::join(root, "config-weave"), "cache-updated")
}

fn check(params: Value) -> Result[CheckResult, string] {
    if common::stamp_fresh(stamp_path(), params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    // `scoop update` with no app name pulls the bucket repositories — the
    // manifest index — without touching any installed app.
    let out = common::action(common::scoop_ps() + "& $scoop update\nexit $LASTEXITCODE\n", #{})?
    if !out.success { return Err(common::failure("scoop update", out)) }
    common::touch_stamp(stamp_path(), "scoop")?
    Ok(ApplyResult::Success)
}
