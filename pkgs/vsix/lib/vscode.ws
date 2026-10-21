// VS Code (and Insiders and VSCodium, through their own CLI) as an
// extension host.
use value
use json
use log
use time
use common
use vrange

// The exit code for "no code CLI was found".
fn missing_code() -> int { 9009 }

// Resolves the code CLI and, when `user` is set, the user's directories:
// <profile>\<dataFolderName>\extensions and <profile>\AppData\Roaming\
// <nameShort>, with both names read from the installation's product.json
// (.vscode/Code, .vscode-insiders/Code - Insiders, .vscode-oss/VSCodium).
// The profile comes from the ProfileList key of the user's SID, so a user
// who has never logged on (and so has no profile) is an error rather than
// a directory created where Windows will not look.
fn target_ps() -> string {
    "$prof = $null\n" +
    "if ($env:CW_USER) {{\n" +
    "  try {{ $sid = (New-Object Security.Principal.NTAccount($env:CW_USER)).Translate([Security.Principal.SecurityIdentifier]).Value }} catch {{ throw ('unknown user ' + $env:CW_USER) }}\n" +
    "  $pl = Get-ItemProperty -LiteralPath ('HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\' + $sid) -ErrorAction SilentlyContinue\n" +
    "  if ($pl -and $pl.ProfileImagePath) {{ $prof = [Environment]::ExpandEnvironmentVariables($pl.ProfileImagePath) }}\n" +
    "  if (-not $prof -or -not (Test-Path -LiteralPath $prof)) {{ throw ('user ' + $env:CW_USER + ' has no profile yet; it is created at their first logon') }}\n" +
    "}}\n" +
    "$code = $env:CW_CODE\n" +
    "if ($code -and -not (Test-Path -LiteralPath $code)) {{ throw ('code CLI ' + $code + ' does not exist') }}\n" +
    "if (-not $code) {{\n" +
    "  $bases = @()\n" +
    "  if ($prof) {{ $bases += Join-Path $prof 'AppData\\Local\\Programs' }}\n" +
    "  $bases += Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs'\n" +
    "  $bases += $env:ProgramFiles\n" +
    "  foreach ($b in $bases) {{ foreach ($rel in 'Microsoft VS Code\\bin\\code.cmd', 'Microsoft VS Code Insiders\\bin\\code-insiders.cmd', 'VSCodium\\bin\\codium.cmd') {{\n" +
    "    $c = Join-Path $b $rel\n" +
    "    if (-not $code -and (Test-Path -LiteralPath $c)) {{ $code = $c }}\n" +
    "  }} }}\n" +
    "  if (-not $code) {{ foreach ($n in 'code.cmd', 'code-insiders.cmd', 'codium.cmd') {{ if (-not $code) {{ $code = (Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1).Source }} }} }}\n" +
    "}}\n" +
    "if (-not $code) {{ exit 9009 }}\n" +
    "$ext = ''; $ud = ''\n" +
    "if ($prof) {{\n" +
    "  $root = Split-Path (Split-Path $code)\n" +
    "  $pj = @((Join-Path $root 'resources\\app\\product.json')) + @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {{ Join-Path $_.FullName 'resources\\app\\product.json' }}) | Where-Object {{ Test-Path -LiteralPath $_ }} | Select-Object -First 1\n" +
    "  $data = '.vscode'; $short = 'Code'\n" +
    "  if ($pj) {{ $p = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json; if ($p.dataFolderName) {{ $data = $p.dataFolderName }}; if ($p.nameShort) {{ $short = $p.nameShort }} }}\n" +
    "  $ext = Join-Path $prof ($data + '\\extensions')\n" +
    "  $ud = Join-Path $prof ('AppData\\Roaming\\' + $short)\n" +
    "}}\n" +
    "ConvertTo-Json -Compress -InputObject @{{ code = $code; extensions_dir = $ext; user_data_dir = $ud }}\n"
}

// What a code CLI acts on, as a map: code (the CLI itself) and, for a
// named user, extensions_dir and user_data_dir. None when no code CLI is
// installed.
fn target(user: string, code: string) -> Result[Option[Value], string] {
    let out = common::run_ps(target_ps(), #{ "CW_USER": Value::String(user), "CW_CODE": Value::String(code) }, 120)?
    if out.code == missing_code() { return Ok(None) }
    if !out.success { return Err(common::failure("finding the VS Code CLI", out)) }
    let m = json::parse(out.stdout.trim())?
    common::cmd_safe("extensions directory", common::get_str(m, "extensions_dir"))?
    common::cmd_safe("user-data directory", common::get_str(m, "user_data_dir"))?
    Ok(Some(m))
}

// Runs the CLI with `args` (plus the user's directories). code.cmd is a
// batch file, so every argument has passed cmd_safe. Native stderr must
// not become a terminating PowerShell error, hence 'Continue'.
fn run(t: Value, args: List[string]) -> Result[CmdOutput, string] {
    let all = args.clone()
    let ext = common::get_str(t, "extensions_dir")
    let ud = common::get_str(t, "user_data_dir")
    if ext != "" { all.push("--extensions-dir"); all.push(ext) }
    if ud != "" { all.push("--user-data-dir"); all.push(ud) }
    let script = "$a = @($env:CW_ARGS -split [char]10)\n" +
        "if ($env:CW_EXT) {{ $null = New-Item -ItemType Directory -Force -Path $env:CW_EXT }}\n" +
        "$ErrorActionPreference = 'Continue'\n" +
        "& $env:CW_CODE @a 2>&1 | ForEach-Object {{ [string]$_ }}\n" +
        "exit $LASTEXITCODE\n"
    common::run_ps(script, #{
        "CW_CODE": Value::String(common::get_str(t, "code")),
        "CW_ARGS": Value::String(all.join("\n")),
        "CW_EXT": Value::String(ext)
    }, 1800)
}

// Installed extensions as lower-cased id -> version.
fn installed(t: Value) -> Result[Map[string, string], string] {
    let out = run(t, ["--list-extensions", "--show-versions"])?
    if !out.success { return Err(common::failure("code --list-extensions", out)) }
    let m: Map[string, string] = #{}
    for line in out.stdout.split("\n") {
        let l = line.trim()
        if let Some(at) = l.find("@") {
            m.insert(l.slice(0, at).to_lower(), l.slice(at + 1, l.len()))
        }
    }
    Ok(m)
}

fn is_configured(t: Value, id: string, version: string, present: bool) -> Result[bool, string] {
    let have = installed(t)?
    let v = have.get(id.to_lower())
    if !present { return Ok(v.is_none()) }
    if v.is_none() { return Ok(false) }
    if vrange::any(version) { return Ok(true) }
    let have = v.unwrap()
    if common::same_version(have, version) { return Ok(true) }
    vrange::satisfies("extension " + id, have, version, "code --list-extensions --show-versions")
}

// `what` is an id, id@version or a .vsix path. A Marketplace install is
// a download, so a failed one is tried up to three times (the CLI has no
// retry of its own and fails on a dropped TLS connection).
fn install(t: Value, what: string, from_marketplace: bool) -> Result[unit, string] {
    let attempts = if from_marketplace { 3 } else { 1 }
    let n = 1
    loop {
        let out = run(t, ["--install-extension", what, "--force"])?
        if out.success { return Ok(()) }
        if n >= attempts { return Err(common::failure("code --install-extension " + what, out)) }
        log::warn("code --install-extension " + what + " failed (exit " + str(out.code) + "), trying again")
        n = n + 1
        time::sleep(10000)
    }
    Ok(())
}

fn uninstall(t: Value, id: string) -> Result[unit, string] {
    let out = run(t, ["--uninstall-extension", id])?
    if !out.success { return Err(common::failure("code --uninstall-extension " + id, out)) }
    Ok(())
}
