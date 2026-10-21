// Visual Studio (2017 to 2026) as an extension host: finding instances
// with vswhere, finding installed extensions, and running VSIXInstaller.
// This package does not use the visual_studio package; it carries its own
// vswhere code so either can be vendored alone.
use value
use fs
use path
use vrange
use shell
use json
use env
use time
use log
use common

fn is_digits(s: string) -> bool {
    if s == "" { return false }
    s.chars().all(|c| c >= '0' && c <= '9')
}

// vs_version: "" (every instance), a major ("16") or a vswhere range
// ("[16.0,17.0)").
fn version_range(v: string) -> Result[string, string] {
    let t = v.trim()
    if t == "" { return Ok("") }
    if is_digits(t) {
        let major = t.parse_int().unwrap_or(0)
        return Ok("[" + str(major) + ".0," + str(major + 1) + ".0)")
    }
    let bad = Err("'vs_version' must be empty, a major version (15 to 18) or a vswhere range such as [16.0,17.0), got '" + v + "'")
    if t.len() < 3 { return bad }
    let open = t.slice(0, 1)
    let close = t.slice(t.len() - 1, t.len())
    if !(open == "[" || open == "(") || !(close == "]" || close == ")") { return bad }
    let inner = t.slice(1, t.len() - 1)
    if !inner.contains(",") || !inner.chars().all(|c| (c >= '0' && c <= '9') || c == '.' || c == ',') { return bad }
    Ok(t)
}

// vs_products: "*" or product ids separated by spaces or commas.
fn validate_products(p: string) -> Result[unit, string] {
    let allowed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.*, "
    if p.trim() == "" || !p.chars().all(|c| allowed.contains(str(c))) {
        return Err("'vs_products' must be * or product ids such as Microsoft.VisualStudio.Product.Professional, got '" + p + "'")
    }
    Ok(())
}

fn installer_dir() -> string {
    let pf86 = env::get("ProgramFiles(x86)").unwrap_or("C:\\Program Files (x86)")
    path::join(pf86, "Microsoft Visual Studio\\Installer")
}

// Complete instances matching the products and range. Build Tools and the
// test agent take no extensions, so they never match.
fn instances(products: string, range: string) -> Result[List[Value], string] {
    let out: List[Value] = []
    let exe = path::join(installer_dir(), "vswhere.exe")
    if !fs::is_file(exe) { return Ok(out) }
    let prods = products.replace(",", " ").split(" ").filter(|p| p != "").join(" ")
    let cmd = "\"" + exe + "\" -prerelease -products " + prods + " -format json -utf8 -nologo"
    if range != "" { cmd = cmd + " -version " + range }
    let res = shell::run(cmd, Value::Null)?
    if !res.success { return Err(common::failure("vswhere", res)) }
    let text = res.stdout.trim()
    if text == "" { return Ok(out) }
    if let Some(items) = json::parse(text)?.as_list() {
        for inst in items {
            let pid = common::get_str(inst, "productId").to_lower()
            if pid.ends_with(".buildtools") || pid.ends_with(".testagent") { continue }
            out.push(inst)
        }
    }
    Ok(out)
}

fn major(inst: Value) -> string {
    common::get_str(inst, "installationVersion").split(".").get(0).unwrap_or("")
}

// Where an instance keeps extensions: per machine under the instance's
// Common7\IDE (Extensions, where VSIXInstaller /admin puts them, and
// CommonExtensions, where the installer's own components go); per user
// under %LOCALAPPDATA%\Microsoft\VisualStudio\<major>.0_<instanceId> of
// the account config-weave runs as.
fn roots(inst: Value, scope: string) -> List[string] {
    if scope == "user" {
        let local = env::get("LOCALAPPDATA").unwrap_or(path::join(env::home_dir(), "AppData\\Local"))
        let rel = "Microsoft\\VisualStudio\\" + major(inst) + ".0_" + common::get_str(inst, "instanceId") + "\\Extensions"
        let out = [path::join(local, rel)]
        // SYSTEM's profile lives under System32, and VSIXInstaller is a
        // 32-bit process, so WOW64 redirects its per-user installs into
        // SysWOW64\config\systemprofile.
        let sys32 = env::get("SystemRoot").unwrap_or("C:\\Windows") + "\\System32\\"
        if local.to_lower().starts_with(sys32.to_lower()) {
            let wow = env::get("SystemRoot").unwrap_or("C:\\Windows") + "\\SysWOW64\\" + local.slice(sys32.len(), local.len())
            out.push(path::join(wow, rel))
        }
        return out
    }
    let ide = path::join(common::get_str(inst, "installationPath"), "Common7\\IDE")
    [path::join(ide, "Extensions"), path::join(ide, "CommonExtensions")]
}

// Every installed copy of extension `id` under the roots, as
// { dir, version } maps.
fn installed(inst: Value, scope: string, id: string) -> Result[List[Value], string] {
    let script = common::manifest_identity_ps() +
        "$found = @()\n" +
        "foreach ($root in ($env:CW_ROOTS -split [char]10)) {{\n" +
        "  if (-not $root -or -not (Test-Path -LiteralPath $root)) {{ continue }}\n" +
        "  foreach ($m in Get-ChildItem -LiteralPath $root -Recurse -Filter extension.vsixmanifest -File -ErrorAction SilentlyContinue) {{\n" +
        "    try {{ $idv = Get-VsixIdentity ([IO.File]::ReadAllText($m.FullName)) }} catch {{ continue }}\n" +
        "    if ($idv[0] -ieq $env:CW_ID) {{ $found += @{{ dir = $m.DirectoryName; version = $idv[1] }} }}\n" +
        "  }}\n" +
        "}}\n" +
        "ConvertTo-Json -Compress -Depth 3 -InputObject @{{ found = @($found) }}\n"
    let m = common::ps_json("looking for extension " + id, script, #{
        "CW_ROOTS": Value::String(roots(inst, scope).join("\n")),
        "CW_ID": Value::String(id)
    })?
    Ok(common::get_list(m, "found"))
}

// Whether any installed copy satisfies the version range ("" or * = any).
fn has(found: List[Value], version: string) -> Result[bool, string] {
    if vrange::any(version) { return Ok(!found.is_empty()) }
    for f in found {
        let have = common::get_str(f, "version")
        let src = path::join(common::get_str(f, "dir"), "extension.vsixmanifest")
        if common::same_version(have, version) || vrange::satisfies("extension", have, version, src)? { return Ok(true) }
    }
    Ok(false)
}

// The instance's own VSIXInstaller, else the Visual Studio Installer's
// shared copy.
fn vsix_installer(inst: Value) -> Result[string, string] {
    let own = path::join(common::get_str(inst, "installationPath"), "Common7\\IDE\\VSIXInstaller.exe")
    if fs::is_file(own) { return Ok(own) }
    let shared = path::join(installer_dir(), "resources\\app\\ServiceHub\\Services\\Microsoft.VisualStudio.Setup.Service\\VSIXInstaller.exe")
    if fs::is_file(shared) { return Ok(shared) }
    Err("no VSIXInstaller.exe found for the instance at " + common::get_str(inst, "installationPath"))
}

// VSIXInstaller must not run while the instance's devenv.exe is open: it
// would wait for it to close, or schedule the change for the next start.
fn ensure_not_running(inst: Value) -> Result[unit, string] {
    let script = "$dir = $env:CW_DIR.TrimEnd('\\') + '\\'\n" +
        "$p = @(Get-Process -Name devenv -ErrorAction SilentlyContinue | Where-Object {{ $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) }})\n" +
        "if ($p.Count) {{ [Console]::Error.WriteLine(($p | ForEach-Object {{ 'devenv.exe ' + $_.Id }}) -join ', '); exit 3 }}\n"
    let p = common::get_str(inst, "installationPath")
    let out = common::run_ps(script, #{ "CW_DIR": Value::String(p) }, 120)?
    if out.code == 3 { return Err("Visual Studio is running from " + p + " (" + out.stderr.trim() + "); close it before extensions are installed or removed") }
    if !out.success { return Err(common::failure("looking for running devenv.exe", out)) }
    Ok(())
}

// Runs VSIXInstaller with `args` plus a /logFile, waits for it, and
// returns its exit code with the log's last lines in stdout.
fn run_installer(exe: string, args: string) -> Result[CmdOutput, string] {
    let log_name = "config-weave-vsix-" + str(time::now_millis()) + ".log"
    let script = "$p = Start-Process -FilePath $env:CW_EXE -ArgumentList ($env:CW_ARGS + ' /logFile:' + $env:CW_LOG) -Wait -PassThru\n" +
        "$code = $p.ExitCode\n" +
        // The log goes to the temp directory of the account, which for
        // SYSTEM is C:\Windows\SystemTemp on current Windows.
        "if ($code -ne 0) {{\n" +
        "  foreach ($d in @($env:TEMP, [IO.Path]::GetTempPath(), (Join-Path $env:SystemRoot 'SystemTemp'), (Join-Path $env:SystemRoot 'Temp')) | Select-Object -Unique) {{\n" +
        "    $f = Join-Path $d $env:CW_LOG\n" +
        "    if ($d -and (Test-Path -LiteralPath $f)) {{ 'log: ' + $f; Get-Content -LiteralPath $f | Where-Object {{ $_ -match 'Exception|error|Skipping|not installable|already installed' }} | Select-Object -Last 8; break }}\n" +
        "  }}\n" +
        "}}\n" +
        "exit $code\n"
    log::info("VSIXInstaller " + args)
    common::run_ps(script, #{
        "CW_EXE": Value::String(exe),
        "CW_ARGS": Value::String(args),
        "CW_LOG": Value::String(log_name)
    }, 3600)
}

// VSIXInstaller exit codes worth naming.
fn meaning(code: int) -> string {
    if code == 1001 { return "already installed" }
    if code == 1002 { return "not installed" }
    if code == 2001 { return "the extension does not apply to this product or version" }
    if code == 2003 { return "the extension is not installable on any installed product (check its InstallationTarget and Prerequisites)" }
    if code == 2004 { return "blocked by a running Visual Studio process" }
    ""
}

fn install(inst: Value, scope: string, file: string) -> Result[unit, string] {
    ensure_not_running(inst)?
    let exe = vsix_installer(inst)?
    let args = "/quiet " + (if scope == "machine" { "/admin " } else { "" }) + "/instanceIds:" + common::get_str(inst, "instanceId") + " \"" + file + "\""
    let out = run_installer(exe, args)?
    // 1001: this version is already installed.
    if out.code == 0 || out.code == 1001 { return Ok(()) }
    let m = meaning(out.code)
    Err("VSIXInstaller failed for the instance at " + common::get_str(inst, "installationPath") + " (exit " + str(out.code) + (if m != "" { ": " + m } else { "" }) + ")\n" + out.stdout.trim())
}

fn uninstall(inst: Value, scope: string, id: string) -> Result[unit, string] {
    ensure_not_running(inst)?
    let exe = vsix_installer(inst)?
    let args = "/quiet " + (if scope == "machine" { "/admin " } else { "" }) + "/instanceIds:" + common::get_str(inst, "instanceId") + " /uninstall:" + id
    // Whether it is gone is decided by looking, not by the exit code.
    let out = run_installer(exe, args)?
    if installed(inst, scope, id)?.is_empty() { return Ok(()) }
    // A per-user uninstall only marks the directory for deletion the next
    // time devenv starts, and an account that never runs Visual Studio
    // (SYSTEM) never gets there. Once VSIXInstaller has uninstalled it, or
    // says it is not installed (1002), what is left is such a directory,
    // and it is deleted here.
    if scope == "user" && (out.code == 0 || out.code == 1002) {
        for f in installed(inst, scope, id)? { fs::delete_dir(common::get_str(f, "dir"))? }
        if installed(inst, scope, id)?.is_empty() { return Ok(()) }
    }
    let m = meaning(out.code)
    Err("VSIXInstaller /uninstall failed for the instance at " + common::get_str(inst, "installationPath") + " (exit " + str(out.code) + (if m != "" { ": " + m } else { "" }) + ")\n" + out.stdout.trim())
}
