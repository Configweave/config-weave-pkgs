use value
use common

// The stamp file's mtime records the last refresh this resource performed.
// It is per manager: a host may run more than one, and a refresh of winget's
// sources says nothing about anyone else's index.
fn stamp_path() -> string { "C:/ProgramData/config-weave/winget-cache-updated" }

fn check(params: Value) -> Result[CheckResult, string] {
    if common::stamp_fresh(stamp_path(), params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    // Refreshes the source manifests only; installed packages are untouched.
    let out = common::action(common::winget_ps() + "& $winget source update --disable-interactivity\nexit $LASTEXITCODE\n", #{})?
    if !out.success { return Err(common::failure("winget source update", out)) }
    common::touch_stamp(stamp_path(), "winget")?
    Ok(ApplyResult::Success)
}
