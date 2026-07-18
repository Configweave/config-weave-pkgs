use value
use shell
use registry
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn validate(params: Value) -> Result[unit, string] {
    let mode = param_str(params, "mode", "oobe")
    if mode != "oobe" && mode != "audit" {
        return Err("invalid 'mode' value '" + mode + "' (expected oobe or audit)")
    }
    let sd = param_str(params, "shutdown", "quit")
    if sd != "quit" && sd != "shutdown" && sd != "reboot" {
        return Err("invalid 'shutdown' value '" + sd + "' (expected quit, shutdown or reboot)")
    }
    if param_bool(params, "vm", false) && (!param_bool(params, "generalize", true) || mode != "oobe") {
        return Err("'vm' (/mode:vm) requires generalize = true and mode = oobe")
    }
    Ok(())
}

// Windows Setup image states (HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\
// Setup\State, value ImageState):
//   IMAGE_STATE_COMPLETE                  normal running installation
//   IMAGE_STATE_UNDEPLOYABLE              sysprep in flight/failed, or booted
//                                         into audit mode
//   IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE   after sysprep /generalize /oobe
//   IMAGE_STATE_GENERALIZE_RESEAL_TO_AUDIT  after sysprep /generalize /audit
//   IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE   after sysprep /oobe (no generalize)
//   IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT  after sysprep /audit (no generalize)
// The SPECIALIZE_RESEAL values come from the documented Setup States enum but
// are unverified against a live no-generalize run; the GENERALIZE pair is the
// well-attested (and test-covered) path.
fn target_state(params: Value) -> string {
    let gen = if param_bool(params, "generalize", true) { "GENERALIZE" } else { "SPECIALIZE" }
    let to = if param_str(params, "mode", "oobe") == "audit" { "AUDIT" } else { "OOBE" }
    "IMAGE_STATE_" + gen + "_RESEAL_TO_" + to
}

fn image_state() -> Result[string, string] {
    let v = registry::read("HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State", "ImageState")?
    if let Some(s) = v {
        return Ok(s.as_string().unwrap_or("").trim())
    }
    Err("Setup State has no ImageState value; is this a Windows host?")
}

fn arg_line(params: Value) -> string {
    let gen = if param_bool(params, "generalize", true) { " /generalize" } else { "" }
    let una = param_str(params, "unattend", "")
    let o_una = if una != "" { " /unattend:" + una } else { "" }
    let o_vm = if param_bool(params, "vm", false) { " /mode:vm" } else { "" }
    "/" + param_str(params, "mode", "oobe") + gen + " /quiet /" + param_str(params, "shutdown", "quit") + o_una + o_vm
}

// Diagnostics only — never mask the real error when the log is unreadable.
fn panther_tail() -> string {
    let script = "Get-Content \"$env:WINDIR\\System32\\Sysprep\\Panther\\setuperr.log\" -Tail 20 -ErrorAction SilentlyContinue | Out-String"
    if let Ok(out) = shell::powershell(script, Value::Null) {
        if out.success { return out.stdout.trim() }
    }
    ""
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    if image_state()? == target_state(params) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let argline = arg_line(params)
    log::info("running sysprep " + argline)
    // sysprep.exe detaches by default — Start-Process -Wait holds until the
    // pass finishes. With /shutdown or /reboot the machine goes away right
    // after; if the transport dies mid-wait the step errors instead (known
    // limitation).
    let script = "$ErrorActionPreference='Stop'; $p = Start-Process -FilePath \"$env:WINDIR\\System32\\Sysprep\\sysprep.exe\" -ArgumentList " + ps_q(argline) + " -Wait -PassThru; exit $p.ExitCode"
    let out = shell::powershell(script, Value::Null)?
    if !out.success {
        return Err("sysprep exited " + str(out.code) + ": " + out.stderr.trim() + "\nsetuperr.log tail:\n" + panther_tail())
    }
    let sd = param_str(params, "shutdown", "quit")
    if sd != "quit" {
        // the machine is shutting down or rebooting — closest available signal
        return Ok(ApplyResult::RebootRequired)
    }
    // sysprep has historically exited 0 on some failed generalizes; trust the
    // resulting ImageState, not the exit code.
    let state = image_state()?
    if state != target_state(params) {
        return Err("sysprep exited 0 but ImageState is '" + state + "' (expected '" + target_state(params) + "')\nsetuperr.log tail:\n" + panther_tail())
    }
    Ok(ApplyResult::Success)
}
