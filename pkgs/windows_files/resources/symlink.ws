use value
use log
use common

fn kind(params: Value) -> Result[string, string] {
    let k = common::param_str(params, "kind", "symbolic")
    if k == "symbolic" || k == "junction" { return Ok(k) }
    Err("invalid 'kind' value '" + k + "' (expected :symbolic or :junction)")
}

fn target_type(params: Value) -> Result[string, string] {
    let t = common::param_str(params, "target_type", "auto")
    if t == "auto" || t == "file" || t == "directory" { return Ok(t) }
    Err("invalid 'target_type' value '" + t + "' (expected :auto, :file or :directory)")
}

// cmd.exe creates junctions, and it reads these characters even inside an
// argument, so a junction path or target may not hold them.
fn cmd_safe(label: string, s: string) -> Result[unit, string] {
    for c in ["&", "|", "<", ">", "^", "%", "!", "\""] {
        if s.contains(c) { return Err("'" + label + "' of a junction must not contain '" + c + "', got '" + s + "'") }
    }
    Ok(())
}

// [path, target, kind, target_type], validated by check and apply alike.
fn params_of(params: Value) -> Result[List[string], string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let k = kind(params)?
    let tt = target_type(params)?
    let target = common::param_str(params, "target", "")
    if common::want_present(params)? {
        if target == "" { return Err("'target' is required when ensure is :present") }
        if target.contains("\n") || target.contains("\r") { return Err("'target' must not contain a line break") }
        if k == "junction" {
            // A junction's target is always an absolute local directory.
            common::require_path("target", target)?
            cmd_safe("path", p)?
            cmd_safe("target", target)?
            if tt == "file" { return Err("a junction always points at a directory; drop target_type = :file") }
        }
    }
    Ok([p, target, k, tt])
}

// { exists, link, dir, target, target_dir, target_exists } for the path
// itself, never following it: a dangling link exists.
fn probe(p: string, target: string) -> Result[Value, string] {
    common::ps_json("reading " + p,
        "$p = " + common::ps_q(p) + "\n" +
        "$t = " + common::ps_q(target) + "\n" +
        "$i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue\n" +
        // Relative symlink targets resolve against the link's directory.
        "$tt = $null\n" +
        "if ($t -ne '') {{ $abs = if ([IO.Path]::IsPathRooted($t)) {{ $t }} else {{ [IO.Path]::Combine([IO.Path]::GetDirectoryName($p), $t) }}; $tt = Get-Item -LiteralPath $abs -Force -ErrorAction SilentlyContinue }}\n" +
        "$o = [ordered]@{{ exists = ($null -ne $i); link = ''; dir = $false; target = ''; target_exists = ($null -ne $tt); target_dir = ($null -ne $tt -and $tt.PSIsContainer) }}\n" +
        "if ($null -ne $i) {{\n" +
        "  $o.link = [string]$i.LinkType\n" +
        "  $o.dir = (($i.Attributes -band [IO.FileAttributes]::Directory) -ne 0)\n" +
        "  $o.target = [string](@($i.Target) | Select-Object -First 1)\n" +
        "}}\n" +
        "[pscustomobject]$o | ConvertTo-Json -Compress\n"
    )
}

fn is_link(st: Value) -> bool {
    let l = common::get_str(st, "link")
    l == "SymbolicLink" || l == "Junction"
}

fn not_a_link_error(p: string) -> string {
    "'" + p + "' exists and is not a symbolic link or junction; refusing to replace it"
}

// Whether a link should be a directory link: by target_type, else by what
// the target is now. A dangling :auto target makes a file link.
fn want_dir(k: string, tt: string, st: Value) -> bool {
    if k == "junction" || tt == "directory" { return true }
    if tt == "file" { return false }
    common::get_bool(st, "target_dir")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let a = params_of(params)?
    let p = a.get(0).unwrap_or("")
    let target = a.get(1).unwrap_or("")
    let k = a.get(2).unwrap_or("")
    let st = probe(p, target)?
    let exists = common::get_bool(st, "exists")
    if !common::want_present(params)? {
        if !exists { return Ok(CheckResult::AlreadyConfigured) }
        if !is_link(st) { return Err(not_a_link_error(p)) }
        return Ok(CheckResult::NotConfigured)
    }
    if !exists { return Ok(CheckResult::NotConfigured) }
    if !is_link(st) { return Err(not_a_link_error(p)) }
    let want_link = if k == "junction" { "Junction" } else { "SymbolicLink" }
    if common::get_str(st, "link") != want_link { return Ok(CheckResult::NotConfigured) }
    if common::norm_path(common::get_str(st, "target")) != common::norm_path(target) { return Ok(CheckResult::NotConfigured) }
    if common::get_bool(st, "dir") != want_dir(k, a.get(3).unwrap_or(""), st) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

// Removes the link itself; Directory.Delete on a directory link or junction
// never touches what it points at.
fn ps_remove_link() -> string {
    "$i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue\n" +
    "if ($null -ne $i) {{\n" +
    "  if (($i.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {{ [IO.Directory]::Delete($p, $false) }} else {{ [IO.File]::Delete($p) }}\n" +
    "}}\n"
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let a = params_of(params)?
    let p = a.get(0).unwrap_or("")
    let target = a.get(1).unwrap_or("")
    let k = a.get(2).unwrap_or("")
    let st = probe(p, target)?
    let exists = common::get_bool(st, "exists")
    if exists && !is_link(st) { return Err(not_a_link_error(p)) }
    let head = "$p = " + common::ps_q(p) + "\n$t = " + common::ps_q(target) + "\n"
    if !common::want_present(params)? {
        if !exists { return Ok(ApplyResult::Success) }
        log::info("removing link " + p)
        common::ps_run("removing link " + p, head + ps_remove_link())?
        return Ok(ApplyResult::Success)
    }
    let create = if k == "junction" {
        // mklink /J creates a junction even when the target is missing.
        "$out = & cmd.exe /d /c mklink /J $p $t 2>&1\n" +
        "if ($LASTEXITCODE -ne 0) {{ throw ('mklink /J failed (exit ' + $LASTEXITCODE + '): ' + ($out -join ' ')) }}\n"
    } else {
        // CreateSymbolicLink directly: New-Item in 5.1 refuses a missing
        // target and treats [] in the target as wildcards.
        "Add-Type -Namespace CwFiles -Name Native -MemberDefinition '[DllImport(\"kernel32.dll\", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool CreateSymbolicLink(string link, string target, int flags);'\n" +
        "if (-not [CwFiles.Native]::CreateSymbolicLink($p, $t, " + (if want_dir(k, a.get(3).unwrap_or(""), st) { "1" } else { "0" }) + ")) {{ throw (New-Object System.ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error())) }}\n"
    }
    log::info("linking " + p + " -> " + target)
    common::ps_run("linking " + p + " -> " + target,
        head +
        "$parent = [IO.Path]::GetDirectoryName($p)\n" +
        "if ($parent) {{ $null = [IO.Directory]::CreateDirectory($parent) }}\n" +
        ps_remove_link() + create
    )?
    Ok(ApplyResult::Success)
}
