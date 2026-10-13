use value
use common

// Describes the path itself and never follows a link: a dangling symbolic
// link or junction exists, and a link to a directory reports is_link with
// link_type rather than standing in for its target.
fn gather(params: Value) -> Result[Value, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let want_hash = common::param_bool(params, "sha256", false)
    common::ps_json("reading " + p,
        "$p = " + common::ps_q(p) + "\n" +
        "$i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue\n" +
        "if ($null -eq $i) {{ [pscustomobject]@{{ path = $p; exists = $false }} | ConvertTo-Json -Compress; exit 0 }}\n" +
        "$link = [string]$i.LinkType\n" +
        "$isLink = ($link -eq 'SymbolicLink' -or $link -eq 'Junction')\n" +
        "$isDir = (($i.Attributes -band [IO.FileAttributes]::Directory) -ne 0)\n" +
        "$o = [ordered]@{{\n" +
        "  path = $p; exists = $true\n" +
        "  is_file = (-not $isDir -and -not $isLink); is_dir = ($isDir -and -not $isLink); is_link = $isLink\n" +
        "  link_type = $(if ($link -eq 'SymbolicLink') {{ 'symbolic' }} elseif ($link -eq 'Junction') {{ 'junction' }} else {{ '' }})\n" +
        "  target = [string](@($i.Target) | Select-Object -First 1)\n" +
        "  size = $(if ($isDir) {{ [int64]0 }} else {{ [int64]$i.Length }})\n" +
        "  attributes = @(([string]$i.Attributes) -split ', ' | Where-Object {{ $_ -ne '' }} | ForEach-Object {{ $_.ToLower() }})\n" +
        "  modified = [int64](([DateTimeOffset]$i.LastWriteTimeUtc).ToUnixTimeSeconds())\n" +
        "  owner = ''; owner_sid = ''\n" +
        "}}\n" +
        "try {{\n" +
        "  $sec = $i.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)\n" +
        "  $sid = $sec.GetOwner([System.Security.Principal.SecurityIdentifier])\n" +
        "  $o.owner_sid = $sid.Value\n" +
        "  try {{ $o.owner = $sid.Translate([System.Security.Principal.NTAccount]).Value }} catch {{ $o.owner = $sid.Value }}\n" +
        "}} catch {{ }}\n" +
        (if want_hash {
            "if ($o.is_file) {{ $o.sha256 = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }}\n"
        } else { "" }) +
        "[pscustomobject]$o | ConvertTo-Json -Compress -Depth 3\n"
    )
}
