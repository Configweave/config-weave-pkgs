use value
use json
use common

fn empty_result() -> Value {
    let none: List[Value] = []
    Value::Map(#{ "count": Value::Int(0), "packages": Value::List(none) })
}

// Every installed package winget knows. With the Microsoft.WinGet.Client
// module this is Get-WinGetPackage (names, ids, versions, including
// packages no source provides). Without it, `winget export`, whose JSON
// has exact ids and versions but no display names and lists only packages
// a source provides, so `name` is empty. The table `winget list` prints is
// never parsed: its headers are localized and its columns truncated.
fn list_ps() -> string {
    common::winget_ps() +
    "$r = @()\n" +
    "if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {{\n" +
    "  Import-Module Microsoft.WinGet.Client\n" +
    "  $r = @(Get-WinGetPackage | ForEach-Object {{ [pscustomobject]@{{ name = [string]$_.Name; id = [string]$_.Id; version = [string]$_.InstalledVersion }} }})\n" +
    "}} else {{\n" +
    "  $f = Join-Path ([IO.Path]::GetTempPath()) ('cw-winget-' + [guid]::NewGuid().ToString() + '.json')\n" +
    "  $o = & $winget export --output $f --include-versions --accept-source-agreements --disable-interactivity\n" +
    "  if (-not (Test-Path -LiteralPath $f)) {{ $o; exit $(if ($LASTEXITCODE) {{ $LASTEXITCODE }} else {{ 1 }}) }}\n" +
    "  $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json\n" +
    "  Remove-Item -LiteralPath $f -Force\n" +
    "  foreach ($s in @($j.Sources)) {{ foreach ($p in @($s.Packages)) {{ $r += [pscustomobject]@{{ name = ''; id = [string]$p.PackageIdentifier; version = [string]$p.Version }} }} }}\n" +
    "}}\n" +
    "ConvertTo-Json -Compress -Depth 4 -InputObject @{{ packages = $r }}\n"
}

fn entry(m: Value) -> Value {
    Value::Map(#{
        "name": Value::String(common::get_str(m, "name")),
        "id": Value::String(common::get_str(m, "id")),
        "version": Value::String(common::get_str(m, "version"))
    })
}

fn gather(params: Value) -> Result[Value, string] {
    let out = common::query(list_ps(), #{})?
    if out.code == common::missing_code() { return Ok(empty_result()) }
    if !out.success { return Err(common::failure("listing winget packages", out)) }
    let m = json::parse(out.stdout.trim())?
    let entries = []
    if let Some(v) = m.get("packages") {
        if let Some(items) = v.as_list() {
            for item in items { entries.push(entry(item)) }
        } else if let Some(single) = v.as_map() {
            entries.push(entry(Value::Map(single)))
        }
    }
    Ok(Value::Map(#{
        "count": Value::Int(entries.len()),
        "packages": Value::List(entries)
    }))
}
