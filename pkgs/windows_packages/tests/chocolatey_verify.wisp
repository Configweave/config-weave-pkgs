use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // The bootstrap landed the real binary, and the cwtest source the
    // chocolatey_source step registered shows up in `choco source list`
    // (via the System32 shim, since PATH edits don't reach this process).
    if !fs::exists("C:\\ProgramData\\chocolatey\\choco.exe") { return Ok(false) }
    let out = shell::powershell("choco source list --limit-output", Value::Null)?
    if !out.success { return Err("choco source list failed: " + out.stderr.trim()) }
    Ok(out.stdout.contains("cwtest|https://example.com/api/v2/"))
}
