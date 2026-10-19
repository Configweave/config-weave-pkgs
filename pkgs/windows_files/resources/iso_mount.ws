use value
use fs
use log
use common
use iso

// What the image is doing now: "detached", or "attached:<letter>" (the
// letter empty when the volume has none).
fn state(p: string) -> Result[string, string] {
    let out = common::run_ps("$p = " + common::ps_q(p) + "\n" + iso::ps_funcs() +
        "$img = Iso-Image $p\n" +
        "if (-not $img.Attached) {{ 'detached' }} else {{ 'attached:' + (Iso-Letter $p) }}\n")?
    if !out.success { return Err(common::failure("reading the state of " + p, out)) }
    Ok(out.stdout.trim())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let want = iso::drive_letter(params)?
    let present = common::want_present(params)?
    // The image may be produced by an earlier step (a download); until it
    // exists it is simply not mounted.
    if !fs::is_file(p) {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let s = state(p)?
    if !present {
        if s == "detached" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if s == "detached" { return Ok(CheckResult::NotConfigured) }
    if want != "" && s.to_upper() != "ATTACHED:" + want { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let want = iso::drive_letter(params)?
    let present = common::want_present(params)?
    if !fs::is_file(p) {
        if !present { return Ok(ApplyResult::Success) }
        return Err("disk image '" + p + "' does not exist")
    }
    let head = "$p = " + common::ps_q(p) + "\n$want = " + common::ps_q(want) + "\n" + iso::ps_funcs()
    if !present {
        log::info("dismounting " + p)
        common::ps_run("dismounting " + p, head + "Dismount-DiskImage -ImagePath $p | Out-Null\n")?
        return Ok(ApplyResult::Success)
    }
    log::info("mounting " + p + if want != "" { " at " + want + ":" } else { "" })
    common::ps_run("mounting " + p, head +
        "$img = Iso-Image $p\n" +
        "if (-not $img.Attached) {{\n" +
        "  if ($want -eq '') {{ Mount-DiskImage -ImagePath $p | Out-Null; [void](Iso-Volume $p); exit 0 }}\n" +
        "  Assert-FreeLetter $want\n" +
        "  Mount-DiskImage -ImagePath $p -NoDriveLetter | Out-Null\n" +
        "}}\n" +
        "if ($want -ne '' -and (Iso-Letter $p) -ne $want) {{ Set-IsoLetter $p $want }}\n")?
    Ok(ApplyResult::Success)
}
