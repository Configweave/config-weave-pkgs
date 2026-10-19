use value
use regex
use log
use common

// One data volume on one disk: initialise a blank disk, make a single
// partition of the whole disk at a drive letter and format it. The safety
// rules decide everything else: the boot and system disks are never
// touched, and a disk that is not blank is only wiped with allow_reformat.

struct Want {
    disk: string,
    letter: string,
    label: string,
    fs: string,
    aus: int,
    style: string,
    allow: bool,
    present: bool,
}

// What apply has to do. action is "none", "build" (initialise, partition
// and format a RAW disk), "reformat" (wipe the disk, then build), "letter"
// (give an existing matching partition the drive letter), "label" or
// "wipe" (ensure = :absent: clear the disk back to RAW).
struct Plan {
    action: string,
    disk: int,
    partition: int,
    why: string,
}

fn want(params: Value) -> Result[Want, string] {
    let disk = common::param_str(params, "disk", "raw").trim()
    if disk == "" { return Err("'disk' must be \"raw\", a disk number, or a serial number or UniqueId") }
    if disk.contains("\n") || disk.contains("\r") { return Err("'disk' must not contain a line break") }
    let letter = common::param_str(params, "drive_letter", "").trim().to_upper()
    if letter.ends_with(":") { letter = letter.slice(0, letter.len() - 1) }
    if letter.len() != 1 || !"DEFGHIJKLMNOPQRSTUVWXYZ".contains(letter) {
        return Err("invalid 'drive_letter' '" + common::param_str(params, "drive_letter", "") + "' (expected one letter from D to Z)")
    }
    let label = common::param_str(params, "label", "")
    if label.len() > 32 || regex::is_match("[\\x00-\\x1f]", label) {
        return Err("invalid 'label' (at most 32 characters, no control characters)")
    }
    let fs = common::param_str(params, "file_system", "ntfs")
    if fs != "ntfs" && fs != "refs" { return Err("invalid 'file_system' value '" + fs + "' (expected :ntfs or :refs)") }
    let style = common::param_str(params, "partition_style", "gpt")
    if style != "gpt" && style != "mbr" { return Err("invalid 'partition_style' value '" + style + "' (expected :gpt or :mbr)") }
    let aus = common::param_int(params, "allocation_unit_size", 0)
    if aus != 0 {
        let pow2 = aus >= 512 && aus <= 2097152
        let v = aus
        while pow2 && v > 1 {
            if v % 2 != 0 { pow2 = false }
            v = v / 2
        }
        if !pow2 { return Err("invalid 'allocation_unit_size' " + str(aus) + " (expected 0 for the default, or a power of two from 512 to 2097152)") }
        if fs == "refs" && aus != 4096 && aus != 65536 { return Err("ReFS supports an 'allocation_unit_size' of 4096 or 65536, not " + str(aus)) }
    }
    Ok(Want {
        disk: disk,
        letter: letter,
        label: label,
        fs: fs,
        aus: aus,
        style: style,
        allow: common::param_bool(params, "allow_reformat", false),
        present: common::want_present(params)?,
    })
}


// The disks and volumes that matter, as one JSON document: the partition
// at the drive letter (and its disk), whatever else holds the letter, the
// selected disk, and the RAW candidates.
fn gather(w: Want) -> Result[Value, string] {
    common::ps_json("reading disks", "$sel = " + common::ps_q(w.disk) + "\n$letter = " + common::ps_q(w.letter) + "\n" +
        "function Letter($c) {{ $s = [string]$c; if ($s -match '^[A-Za-z]$') {{ $s.ToUpper() }} else {{ '' }} }}\n" +
        "function Info($d) {{\n" +
        "  $parts = @()\n" +
        "  if ([string]$d.PartitionStyle -ne 'RAW') {{\n" +
        "    foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {{\n" +
        "      if (@('Reserved', 'Recovery', 'System', 'Unknown') -contains [string]$p.Type) {{ continue }}\n" +
        "      $v = $p | Get-Volume -ErrorAction SilentlyContinue\n" +
        "      $parts += @{{ partition = [int]$p.PartitionNumber; letter = (Letter $p.DriveLetter); fs = [string]$v.FileSystem; label = [string]$v.FileSystemLabel; aus = [int64]$v.AllocationUnitSize }}\n" +
        "    }}\n" +
        "  }}\n" +
        "  @{{ number = [int]$d.Number; style = [string]$d.PartitionStyle; boot = [bool]$d.IsBoot; system = [bool]$d.IsSystem; unique_id = [string]$d.UniqueId; serial = ([string]$d.SerialNumber).Trim(); parts = $parts }}\n" +
        "}}\n" +
        "$r = @{{ at_letter = $null; letter_used = $false; selected = $null; raw = @() }}\n" +
        "$lp = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue\n" +
        "if ($lp) {{\n" +
        "  $v = $lp | Get-Volume -ErrorAction SilentlyContinue\n" +
        "  $r.at_letter = @{{ disk = (Info (Get-Disk -Number $lp.DiskNumber)); partition = [int]$lp.PartitionNumber; fs = [string]$v.FileSystem; label = [string]$v.FileSystemLabel; aus = [int64]$v.AllocationUnitSize }}\n" +
        "}} else {{\n" +
        "  $r.letter_used = [bool](Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue) -or (@(Get-CimInstance Win32_Volume -Filter (\"DriveLetter='\" + $letter + \":'\")).Count -gt 0)\n" +
        "}}\n" +
        "if ($sel -eq 'raw') {{\n" +
        "  $r.raw = @(Get-Disk | Where-Object {{ [string]$_.PartitionStyle -eq 'RAW' -and -not $_.IsBoot -and -not $_.IsSystem }} | ForEach-Object {{ [int]$_.Number }})\n" +
        "}} elseif ($sel -match '^[0-9]{{1,4}}$') {{\n" +
        "  $d = Get-Disk -Number ([int]$sel) -ErrorAction SilentlyContinue\n" +
        "  if (-not $d) {{ throw ('there is no disk number ' + $sel) }}\n" +
        "  $r.selected = Info $d\n" +
        "}} else {{\n" +
        "  $m = @(Get-Disk | Where-Object {{ [string]$_.UniqueId -eq $sel -or ([string]$_.SerialNumber).Trim() -eq $sel }})\n" +
        "  if ($m.Count -eq 0) {{ throw ('no disk has the serial number or UniqueId ''' + $sel + '''') }}\n" +
        "  if ($m.Count -gt 1) {{ throw ($m.Count.ToString() + ' disks match ''' + $sel + ''' (numbers ' + (($m | ForEach-Object {{ $_.Number }}) -join ', ') + '); select one by number or UniqueId') }}\n" +
        "  $r.selected = Info $m[0]\n" +
        "}}\n" +
        "ConvertTo-Json -InputObject $r -Depth 6 -Compress\n")
}

fn fs_name(fs: string) -> string { if fs == "refs" { "ReFS" } else { "NTFS" } }

fn refuse_system(d: Value, what: string) -> Result[unit, string] {
    if common::get_bool(d, "boot") || common::get_bool(d, "system") {
        return Err(what + " is on disk " + str(common::get_int(d, "number")) + ", the boot or system disk, which windows_storage.volume never touches")
    }
    Ok(())
}

// Everything about an existing volume that only a reformat can change.
fn format_drift(w: Want, vol: Value, disk: Value) -> List[string] {
    let out: List[string] = []
    let fs = common::get_str(vol, "fs")
    if fs.to_lower() != w.fs { out.push("file_system is " + (if fs == "" { "none" } else { fs }) + ", want " + fs_name(w.fs)) }
    let have_aus = common::get_int(vol, "aus")
    if w.aus > 0 && have_aus != w.aus { out.push("allocation_unit_size is " + str(have_aus) + ", want " + str(w.aus)) }
    let style = common::get_str(disk, "style").to_lower()
    if style != w.style { out.push("partition_style is " + style.to_upper() + ", want " + w.style.to_upper()) }
    out
}

fn plan(w: Want) -> Result[Plan, string] {
    let g = gather(w)?
    let sel_disk = g.get("selected").unwrap_or(Value::Null)
    let at = g.get("at_letter").unwrap_or(Value::Null)
    let none = Plan { action: "none", disk: -1, partition: -1, why: "" }

    if !at.is_null() {
        let disk = at.get("disk").unwrap_or(Value::Null)
        let n = common::get_int(disk, "number")
        refuse_system(disk, "drive letter " + w.letter + ":")?
        if !sel_disk.is_null() && common::get_int(sel_disk, "number") != n {
            return Err("drive letter " + w.letter + ": is a volume on disk " + str(n) + ", not on the selected disk " + str(common::get_int(sel_disk, "number")))
        }
        if !w.present {
            if !w.allow { return Err("removing volume " + w.letter + ": clears disk " + str(n) + " and destroys its data; set allow_reformat = true to allow it") }
            return Ok(Plan { action: "wipe", disk: n, partition: -1, why: "volume " + w.letter + ": exists" })
        }
        let drift = format_drift(w, at, disk)
        if drift.len() > 0 {
            let why = "volume " + w.letter + ": on disk " + str(n) + ": " + drift.join("; ")
            if !w.allow { return Err(why + ". Changing that means reformatting, which destroys the volume's data; set allow_reformat = true to allow it") }
            return Ok(Plan { action: "reformat", disk: n, partition: -1, why: why })
        }
        if common::get_str(at, "label") != w.label {
            return Ok(Plan { action: "label", disk: n, partition: common::get_int(at, "partition"), why: "label is '" + common::get_str(at, "label") + "'" })
        }
        return Ok(none)
    }

    if !w.present { return Ok(none) }
    if common::get_bool(g, "letter_used") {
        return Err("drive letter " + w.letter + ": is in use by something that is not a disk partition (a CD-ROM, network or subst drive)")
    }

    if sel_disk.is_null() {
        let raw = common::get_list(g, "raw")
        if raw.len() == 0 {
            return Err("there is no volume at " + w.letter + ": and no blank (RAW) disk to create it on, other than the boot and system disks. With disk = \"raw\" the drive letter is what finds the volume once it exists; select the disk by number, serial or UniqueId to repair a changed letter")
        }
        if raw.len() > 1 {
            let nums: List[string] = []
            for r in raw { nums.push(str(r.as_int().unwrap_or(-1))) }
            return Err("found " + str(raw.len()) + " blank (RAW) disks (numbers " + nums.join(", ") + "); select one by number, serial or UniqueId")
        }
        let n = raw.get(0).unwrap_or(Value::Null).as_int().unwrap_or(-1)
        return Ok(Plan { action: "build", disk: n, partition: -1, why: "disk " + str(n) + " is blank" })
    }

    let n = common::get_int(sel_disk, "number")
    refuse_system(sel_disk, "the selected disk")?
    if common::get_str(sel_disk, "style") == "RAW" {
        return Ok(Plan { action: "build", disk: n, partition: -1, why: "disk " + str(n) + " is blank" })
    }
    // A disk that already holds exactly the wanted volume, only without
    // the letter (or at another one), is fixed in place.
    let parts = common::get_list(sel_disk, "parts")
    if parts.len() == 1 {
        let p = parts.get(0).unwrap_or(Value::Null)
        if format_drift(w, p, sel_disk).len() == 0 {
            return Ok(Plan { action: "letter", disk: n, partition: common::get_int(p, "partition"), why: "disk " + str(n) + "'s volume is not at " + w.letter + ":" })
        }
    }
    let desc = common::get_str(sel_disk, "style") + ", " + str(parts.len()) + " data partition(s)"
    if !w.allow {
        return Err("disk " + str(n) + " is not blank (" + desc + "); windows_storage.volume only formats a RAW disk unless allow_reformat = true, which destroys everything on it")
    }
    Ok(Plan { action: "reformat", disk: n, partition: -1, why: "disk " + str(n) + " holds " + desc })
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = plan(want(params)?)?
    if p.action == "none" { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    let p = plan(w)?
    if p.action == "none" { return Ok(ApplyResult::Success) }
    log::info(p.why + ": " + p.action + " disk " + str(p.disk))
    let head = "$n = " + str(p.disk) + "\n$part = " + str(p.partition) + "\n$letter = " + common::ps_q(w.letter) + "\n$label = " + common::ps_q(w.label) + "\n" +
        "$fs = " + common::ps_q(fs_name(w.fs)) + "\n$aus = " + str(w.aus) + "\n$style = " + common::ps_q(w.style.to_upper()) + "\n" +
        "function Ready {{\n" +
        "  $d = Get-Disk -Number $n\n" +
        "  if ($d.IsBoot -or $d.IsSystem) {{ throw ('disk ' + $n + ' is the boot or system disk') }}\n" +
        "  if ($d.IsOffline) {{ Set-Disk -Number $n -IsOffline $false }}\n" +
        "  if ($d.IsReadOnly) {{ Set-Disk -Number $n -IsReadOnly $false }}\n" +
        "}}\n" +
        "function Build {{\n" +
        "  Ready\n" +
        "  if ([string](Get-Disk -Number $n).PartitionStyle -ne 'RAW') {{ throw ('disk ' + $n + ' is no longer blank') }}\n" +
        "  Initialize-Disk -Number $n -PartitionStyle $style\n" +
        "  $p = New-Partition -DiskNumber $n -UseMaximumSize -DriveLetter $letter\n" +
        "  $f = @{{ Partition = $p; FileSystem = $fs; NewFileSystemLabel = $label; Confirm = $false; Force = $true }}\n" +
        "  if ($aus -gt 0) {{ $f.AllocationUnitSize = $aus }}\n" +
        "  Format-Volume @f | Out-Null\n" +
        "}}\n" +
        "function Wipe {{ Ready; Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false }}\n"
    let act = if p.action == "build" {
        "Build\n"
    } else if p.action == "reformat" {
        "Wipe\nBuild\n"
    } else if p.action == "wipe" {
        "Wipe\n"
    } else if p.action == "letter" {
        "Set-Partition -DiskNumber $n -PartitionNumber $part -NewDriveLetter $letter\n" +
        "if ([string](Get-Volume -DriveLetter $letter).FileSystemLabel -cne $label) {{ Set-Volume -DriveLetter $letter -NewFileSystemLabel $label }}\n"
    } else {
        "Set-Volume -DriveLetter $letter -NewFileSystemLabel $label\n"
    }
    common::ps_run(p.action + " disk " + str(p.disk), head + act)?
    Ok(ApplyResult::Success)
}
