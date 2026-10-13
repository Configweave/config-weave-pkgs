use value
use fs
use shell

// The install ran through the SYSTEM task and logged each update it
// installed; the task is unregistered afterwards.
fn verify(facts: Value) -> Result[bool, string] {
    let log = fs::read("C:\\ProgramData\\config-weave\\windows-updates\\install.log")?
    if !log.contains("installed: ") { return Err("install.log names no installed update: " + log) }
    if !log.contains("ResultCode 2") { return Err("install.log shows no successful result: " + log) }
    let out = shell::powershell("@(Get-ScheduledTask -TaskName config-weave-windows-updates -ErrorAction SilentlyContinue).Count", Value::Null)?
    if out.stdout.trim() != "0" { return Err("the update task is still registered") }
    Ok(true)
}
