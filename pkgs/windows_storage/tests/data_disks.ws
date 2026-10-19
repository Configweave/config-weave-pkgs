// Scenario driver for windows_storage.volume on a VM with two blank 4 GiB
// data disks (tests/disk-lab). The disks are selected by the UniqueId the
// guest reports, which is why this is a scenario and not a test: a test's
// properties are fixed before the guest exists.
//
// Symbol params are passed as plain strings: testlab renders a top-level
// string as a symbol when the param is declared `type = "symbol"`.

use testlab
use value

fn key() -> string { "windows_storage.volume" }

fn s(v: string) -> Value { Value::String(v) }

// check, apply, apply: the three-run protocol a `test` step gets.
fn converge(m: Machine, what: string, props: Value) -> Result[bool, string] {
    let c = m.check_resource(key(), props)?
    if c.status != "not_configured" { return Err(what + ": expected not_configured on check, got " + c.status + " (" + c.message + ")") }
    let a = m.apply_resource(key(), props)?
    if a.status != "configured" { return Err(what + ": expected configured on first apply, got " + a.status + " (" + a.message + ")") }
    let b = m.apply_resource(key(), props)?
    if b.status != "already_configured" { return Err(what + ": expected already_configured on second apply, got " + b.status + " (" + b.message + ")") }
    Ok(true)
}

// The step must fail on apply with a message containing `needle`, and so
// change nothing.
fn refused(m: Machine, what: string, props: Value, needle: string) -> Result[bool, string] {
    let a = m.apply_resource(key(), props)?
    if a.status != "error" { return Err(what + ": expected an error, got " + a.status + " (" + a.message + ")") }
    if !a.message.contains(needle) { return Err(what + ": the error does not say '" + needle + "': " + a.message) }
    Ok(true)
}

fn ps(m: Machine, script: string) -> Result[string, string] {
    let r = m.powershell("$ErrorActionPreference='Stop'; " + script)?
    if r.exit_code != 0 { return Err("powershell failed: " + r.stderr.trim()) }
    Ok(r.stdout.trim())
}

// "<fs>|<label>|<aus>|<style>|<disk UniqueId>" of the volume at a letter.
fn describe(m: Machine, letter: string) -> Result[string, string] {
    ps(m, "$p = Get-Partition -DriveLetter " + letter + "; $v = $p | Get-Volume; $d = Get-Disk -Number $p.DiskNumber; " +
        "[string]$v.FileSystem + '|' + $v.FileSystemLabel + '|' + $v.AllocationUnitSize + '|' + $d.PartitionStyle + '|' + $d.UniqueId")
}

// A freshly booted guest's vmlab agent can drop the channel on its first
// execs while it settles, so the first contact is retried until a trivial
// command answers.
fn settle(m: Machine) -> Result[bool, string] {
    for i in 0..30 {
        if let Ok(r) = m.powershell("'ok'") {
            if r.stdout.trim() == "ok" { return Ok(true) }
        }
        if let Err(_) = m.wait_ready(60) { }
    }
    Err(m.name() + ": the guest agent never answered a command")
}

fn run(lab: Lab) -> Result[bool, string] {
    let m = lab.machine("disk01")?
    settle(m)?

    let ids = ps(m, "@(Get-Disk | Where-Object {{ [string]$_.PartitionStyle -eq 'RAW' }} | Sort-Object Number | ForEach-Object {{ $_.UniqueId }}) -join ','")?.split(",")
    if ids.len() != 2 { return Err("expected two blank disks, found: " + ids.join(", ")) }
    let first = ids.get(0).unwrap_or("")
    let second = ids.get(1).unwrap_or("")
    lab.log("blank disks: " + first + ", " + second)

    // --- selection safety ---------------------------------------------------
    refused(m, "two RAW candidates", Value::Map(#{ "drive_letter": s("E") }), "found 2 blank (RAW) disks")?
    refused(m, "boot disk", Value::Map(#{ "disk": s("0"), "drive_letter": s("X") }), "boot or system disk")?
    refused(m, "unknown UniqueId", Value::Map(#{ "disk": s("NO-SUCH-DISK"), "drive_letter": s("X") }), "no disk has the serial number or UniqueId")?

    // --- a blank disk by UniqueId, NTFS with 64K clusters ---------------------
    let data = Value::Map(#{
        "disk": s(first),
        "drive_letter": s("E"),
        "label": s("Data"),
        "allocation_unit_size": Value::Int(65536)
    })
    converge(m, "data volume", data)?
    let got = describe(m, "E")?
    if got != "NTFS|Data|65536|GPT|" + first { return Err("E: is " + got) }

    // --- the only RAW disk left, as ReFS on MBR -------------------------------
    let logs = Value::Map(#{
        "drive_letter": s("F"),
        "label": s("Logs"),
        "file_system": s("refs"),
        "partition_style": s("mbr")
    })
    converge(m, "logs volume", logs)?
    let got = describe(m, "F")?
    if !got.starts_with("ReFS|Logs|") || !got.ends_with("|MBR|" + second) { return Err("F: is " + got) }
    refused(m, "no RAW disk left", Value::Map(#{ "drive_letter": s("G") }), "no blank (RAW) disk")?

    // --- label and letter drift are fixed in place ----------------------------
    ps(m, "Set-Volume -DriveLetter E -NewFileSystemLabel Wrong")?
    converge(m, "label drift", data)?
    if !describe(m, "E")?.starts_with("NTFS|Data|") { return Err("E: label was not restored") }
    ps(m, "Get-Partition -DriveLetter E | Set-Partition -NewDriveLetter K")?
    converge(m, "letter drift", data)?
    let k = ps(m, "[bool](Get-Partition -DriveLetter K -ErrorAction SilentlyContinue)")?
    if k != "False" { return Err("the volume is still at K:") }
    if describe(m, "E")? != "NTFS|Data|65536|GPT|" + first { return Err("E: did not come back as the data volume") }

    // --- nothing is reformatted without allow_reformat ------------------------
    refused(m, "file system drift", Value::Map(#{ "disk": s(first), "drive_letter": s("E"), "label": s("Data"), "file_system": s("refs") }), "allow_reformat")?
    refused(m, "volume on another disk", Value::Map(#{ "disk": s(second), "drive_letter": s("E"), "label": s("Data") }), "not on the selected disk")?
    refused(m, "non-blank disk", Value::Map(#{ "disk": s(second), "drive_letter": s("H") }), "is not blank")?
    if describe(m, "E")? != "NTFS|Data|65536|GPT|" + first { return Err("a refused step changed E:") }

    // --- ... and is with it ------------------------------------------------------
    converge(m, "reformat", Value::Map(#{
        "disk": s(first),
        "drive_letter": s("E"),
        "label": s("Data2"),
        "file_system": s("refs"),
        "allocation_unit_size": Value::Int(65536),
        "allow_reformat": Value::Bool(true)
    }))?
    let got = describe(m, "E")?
    if got != "ReFS|Data2|65536|GPT|" + first { return Err("after the reformat E: is " + got) }

    // --- ensure = :absent clears the disk -------------------------------------
    refused(m, "absent without allow_reformat", Value::Map(#{ "drive_letter": s("F"), "ensure": s("absent") }), "allow_reformat")?
    converge(m, "logs absent", Value::Map(#{ "drive_letter": s("F"), "ensure": s("absent"), "allow_reformat": Value::Bool(true) }))?
    let style = ps(m, "[string](Get-Disk | Where-Object {{ $_.UniqueId -eq '" + second + "' }}).PartitionStyle + '|' + [bool](Get-Partition -DriveLetter F -ErrorAction SilentlyContinue)")?
    if style != "RAW|False" { return Err("after ensure = :absent the second disk is " + style) }
    Ok(true)
}
