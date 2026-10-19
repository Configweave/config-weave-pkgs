// Helpers the ISO resources share: drive letter validation and the
// PowerShell functions that find, mount and re-letter a disk image.
use value
use common

// "" or one drive letter, upper-cased; a trailing colon is accepted.
fn drive_letter(params: Value) -> Result[string, string] {
    let l = common::param_str(params, "drive_letter", "").trim().to_upper()
    if l.ends_with(":") { l = l.slice(0, l.len() - 1) }
    if l == "" { return Ok("") }
    if l.len() != 1 || !"ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(l) {
        return Err("invalid 'drive_letter' '" + common::param_str(params, "drive_letter", "") + "' (expected one letter such as S)")
    }
    Ok(l)
}

// PowerShell functions for the scripts below. The volume of an image that
// was just mounted can take a moment to appear, so Iso-Volume waits for it.
fn ps_funcs() -> string {
    "function Iso-Image($p) {{ Get-DiskImage -ImagePath $p }}\n" +
    "function Iso-Volume($p) {{\n" +
    "  for ($i = 0; $i -lt 40; $i++) {{\n" +
    "    $v = Get-DiskImage -ImagePath $p | Get-Volume -ErrorAction SilentlyContinue\n" +
    "    if ($v) {{ return $v }}\n" +
    "    Start-Sleep -Milliseconds 250\n" +
    "  }}\n" +
    "  throw ('the volume of ''' + $p + ''' never appeared')\n" +
    "}}\n" +
    "function Iso-Letter($p) {{ [string](Iso-Volume $p).DriveLetter }}\n" +
    // A letter is free when no volume and no other drive (network, subst) holds it.
    "function Assert-FreeLetter($l) {{\n" +
    "  $used = @(Get-CimInstance Win32_Volume -Filter (\"DriveLetter='\" + $l + \":'\")).Count -gt 0\n" +
    "  if ($used -or (Get-PSDrive -Name $l -PSProvider FileSystem -ErrorAction SilentlyContinue)) {{ throw ('drive letter ' + $l + ': is already in use') }}\n" +
    "}}\n" +
    "function Set-IsoLetter($p, $l) {{\n" +
    "  Assert-FreeLetter $l\n" +
    "  $v = Iso-Volume $p\n" +
    "  $cv = Get-CimInstance Win32_Volume | Where-Object {{ $_.DeviceID -eq $v.Path }}\n" +
    "  if (-not $cv) {{ throw ('no Win32_Volume for ' + $v.Path) }}\n" +
    "  Set-CimInstance -InputObject $cv -Property @{{ DriveLetter = $l + ':' }}\n" +
    "}}\n"
}
