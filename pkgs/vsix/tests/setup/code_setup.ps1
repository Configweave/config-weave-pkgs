$ErrorActionPreference = 'Stop'
$d = 'C:\weave-vsix'
$null = New-Item -ItemType Directory -Force -Path $d
Add-Type -AssemblyName WindowsBase
function Utf8($s) { [Text.Encoding]::UTF8.GetBytes($s) }
function NewPkg($f, $parts) { if (Test-Path $f) { Remove-Item -LiteralPath $f -Force }; $p = [IO.Packaging.Package]::Open($f, 'Create'); foreach ($k in $parts.Keys) { $t = $p.CreatePart([Uri]::new($k, [UriKind]::Relative), 'application/octet-stream'); $s = $t.GetStream(); $b = $parts[$k]; $s.Write($b, 0, $b.Length); $s.Close() }; $p.Close() }
$m = '<?xml version="1.0" encoding="utf-8"?><PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011"><Metadata><Identity Language="en-US" Id="cw-test" Version="0.0.1" Publisher="config-weave"/><DisplayName>cw-test</DisplayName><Description>config-weave test</Description></Metadata><Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation><Dependencies/><Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets></PackageManifest>'
$j = '{"name":"cw-test","displayName":"cw-test","publisher":"config-weave","version":"0.0.1","engines":{"vscode":"^1.0.0"}}'
NewPkg ($d + '\cw-test.vsix') @{ '/extension.vsixmanifest' = (Utf8 $m); '/extension/package.json' = (Utf8 $j) }
# A local user with a profile, created with userenv's CreateProfile (the
# profile a first logon would make), so no logon right is needed.
$u = 'cwdev'
$pw = 'Cw-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '!a1'
if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) { $null = New-LocalUser -Name $u -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -PasswordNeverExpires }
$sid = (Get-LocalUser -Name $u).SID.Value
if (-not (Test-Path ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sid))) {
  Add-Type -Namespace CW -Name Profile -MemberDefinition '[DllImport("userenv.dll", CharSet = CharSet.Unicode)] public static extern int CreateProfile(string sid, string name, System.Text.StringBuilder path, uint len);'
  $sb = New-Object Text.StringBuilder 260
  $hr = [CW.Profile]::CreateProfile($sid, $u, $sb, 260)
  if ($hr -ne 0) { throw ('CreateProfile failed: 0x' + $hr.ToString('X8')) }
}
# VS Code, the portable zip, unpacked once.
if (-not (Test-Path 'C:\vscode\bin\code.cmd')) {
  $z = 'C:\weave-vsix\vscode.zip'
  for ($i = 0; $i -lt 5 -and -not (Test-Path 'C:\vscode\bin\code.cmd'); $i++) {
    & curl.exe -fsSL --retry 10 --retry-all-errors -C - -o $z 'https://update.code.visualstudio.com/latest/win32-x64-archive/stable'
    if ($LASTEXITCODE -eq 0) { Expand-Archive -LiteralPath $z -DestinationPath 'C:\vscode' -Force }
  }
  if (-not (Test-Path 'C:\vscode\bin\code.cmd')) { throw 'VS Code could not be downloaded' }
  Remove-Item -LiteralPath $z -Force
}
