# Visual Studio Community 2022 with only the core editor: the smallest
# product that takes extensions (Build Tools does not). Installed once.
$vw = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$have = $false
if (Test-Path $vw) { $have = [bool](& $vw -products Microsoft.VisualStudio.Product.Community -version '[17.0,18.0)' -property instanceId) }
if (-not $have) {
  $b = 'C:\weave-vsix-boot\vs_community.exe'
  $null = New-Item -ItemType Directory -Force -Path (Split-Path $b)
  & curl.exe -fsSL --retry 5 --retry-all-errors -o $b 'https://aka.ms/vs/17/release/vs_community.exe'
  if ($LASTEXITCODE -ne 0) { throw ('downloading the bootstrapper failed: ' + $LASTEXITCODE) }
  # On a fresh machine the bootstrapper first updates the installer, which
  # fails now and then on a slow network (exit 5008); it is run again.
  for ($i = 1; $i -le 3; $i++) {
    $p = Start-Process -FilePath $b -ArgumentList '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.CoreEditor' -Wait -PassThru
    if ($p.ExitCode -in 0, 3010) { break }
    if ($i -eq 3) { throw ('vs_community.exe exited ' + $p.ExitCode) }
    Start-Sleep -Seconds 30
  }
}
$ErrorActionPreference = 'Stop'
# Test packages, built with System.IO.Packaging. Visual Studio 2022's
# VSIXInstaller only takes a VSIX v3 package: extension.vsixmanifest plus
# manifest.json and catalog.json.
$d = 'C:\weave-vsix'
$null = New-Item -ItemType Directory -Force -Path $d
Add-Type -AssemblyName WindowsBase
function Utf8($s) { [Text.Encoding]::UTF8.GetBytes($s) }
function Sha($b) { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) }
function NewPkg($f, $parts) {
  if (Test-Path $f) { Remove-Item -LiteralPath $f -Force }
  $p = [IO.Packaging.Package]::Open($f, 'Create')
  foreach ($k in $parts.Keys) {
    $ct = switch -Regex ($k) { 'vsixmanifest$' { 'text/xml' } 'json$' { 'application/json' } 'txt$' { 'text/plain' } default { 'application/octet-stream' } }
    $t = $p.CreatePart([Uri]::new($k, [UriKind]::Relative), $ct)
    $s = $t.GetStream(); $b = $parts[$k]; $s.Write($b, 0, $b.Length); $s.Close()
  }
  $p.Close()
}
function NewVsix($file, $id, $ver, $allUsers, $deps, $extra) {
  $m = Utf8 @"
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Id="$id" Version="$ver" Language="en-US" Publisher="config-weave" />
    <DisplayName>$id</DisplayName>
    <Description xml:space="preserve">config-weave test package</Description>
  </Metadata>
  <Installation AllUsers="$allUsers">
    <InstallationTarget Id="Microsoft.VisualStudio.Community" Version="[17.0,19.0)">
      <ProductArchitecture>amd64</ProductArchitecture>
    </InstallationTarget>
  </Installation>$deps
  <Prerequisites>
    <Prerequisite Id="Microsoft.VisualStudio.Component.CoreEditor" Version="[17.0,)" DisplayName="Visual Studio core editor" />
  </Prerequisites>
</PackageManifest>
"@
  $parts = [ordered]@{ '/extension.vsixmanifest' = $m; '/readme.txt' = (Utf8 ($id + ' ' + $ver)) }
  foreach ($k in $extra.Keys) { $parts[$k] = $extra[$k] }
  $files = @($parts.Keys | ForEach-Object { [ordered]@{ fileName = $_; sha256 = (Sha $parts[$_]) } })
  $dir = '[installdir]\Common7\IDE\Extensions\cw-' + $id.ToLower()
  $mj = [ordered]@{ id = $id; version = $ver; type = 'Vsix'; vsixId = $id; extensionDir = $dir; files = $files; installSizes = @{ targetDrive = 1000 }; dependencies = @{ 'Microsoft.VisualStudio.Component.CoreEditor' = '17.0' } }
  $cj = [ordered]@{ manifestVersion = '1.1'; info = @{ id = ($id + ',version=' + $ver); manifestType = 'Extension' }; packages = @(
    [ordered]@{ id = ('Component.' + $id); version = $ver; type = 'Component'; extension = $true; dependencies = @{ $id = $ver; 'Microsoft.VisualStudio.Component.CoreEditor' = '17.0' }; localizedResources = @(@{ language = 'en-US'; title = $id; description = 'config-weave test package' }) },
    [ordered]@{ id = $id; version = $ver; type = 'Vsix'; payloads = @(@{ fileName = ($id + '.vsix'); size = 1000 }); vsixId = $id; extensionDir = $dir; installSizes = @{ targetDrive = 1000 } }) }
  $parts['/manifest.json'] = Utf8 (ConvertTo-Json -Depth 8 -Compress -InputObject $mj)
  $parts['/catalog.json'] = Utf8 (ConvertTo-Json -Depth 8 -Compress -InputObject $cj)
  NewPkg $file $parts
}
NewVsix ($d + '\plain.vsix') 'ConfigWeave.Test.Plain' '1.0' 'true' '' @{}
NewVsix ($d + '\user.vsix') 'ConfigWeave.Test.User' '1.0' 'false' '' @{}
NewVsix ($d + '\nested2.vsix') 'ConfigWeave.Test.Nested' '2.0' 'true' '' @{}
NewVsix ($d + '\nested1.vsix') 'ConfigWeave.Test.Nested' '1.0' 'true' '' @{}
$dep = "`n  <Dependencies>`n    <Dependency Id=""ConfigWeave.Test.Nested"" DisplayName=""Nested"" Version=""[1.0,)"" d:Source=""File"" Location=""Shared\Nested.vsix"" />`n  </Dependencies>"
NewVsix ($d + '\outer.vsix') 'ConfigWeave.Test.Outer' '1.0' 'true' $dep @{ '/Shared/Nested.vsix' = [IO.File]::ReadAllBytes($d + '\nested1.vsix') }
