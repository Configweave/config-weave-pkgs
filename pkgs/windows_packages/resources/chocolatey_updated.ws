use value
use common

// The stamp file's mtime records the last upgrade this resource performed.
fn stamp_path() -> string { "C:/ProgramData/config-weave/chocolatey-updated" }

fn check(params: Value) -> Result[CheckResult, string] {
    if common::stamp_fresh(stamp_path(), params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    // Chocolatey queries its sources live and keeps no refreshable index, so
    // — as with flatpak — the useful periodic action is upgrading what is
    // installed, not refreshing metadata that does not exist.
    let out = common::action(common::choco_ps() + "& $choco upgrade all -y --no-progress\nexit $LASTEXITCODE\n", #{})?
    let reboot = out.code == 3010 || out.code == 1641
    if !out.success && !reboot { return Err(common::failure("choco upgrade all", out)) }
    common::touch_stamp(stamp_path(), "chocolatey")?
    if reboot { return Ok(ApplyResult::RebootRequired) }
    Ok(ApplyResult::Success)
}
