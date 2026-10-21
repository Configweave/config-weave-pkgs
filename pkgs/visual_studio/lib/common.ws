// Helpers every visual_studio script shares: params, running PowerShell,
// finding instances with vswhere, fetching the bootstrapper and running
// the Visual Studio installer.
use value
use fs
use path
use shell
use json
use http
use hash
use time
use env
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let items: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs {
                if let Some(s) = x.as_string() { items.push(s) }
            }
        }
    }
    items
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

// A JSON field that may be a list, a single collapsed value, or null.
fn get_list(m: Value, key: string) -> List[Value] {
    let out: List[Value] = []
    if let Some(v) = m.get(key) {
        if let Some(items) = v.as_list() {
            for item in items { out.push(item) }
        } else if !v.is_null() {
            out.push(v)
        }
    }
    out
}

// Tools report failures on either stream or only through the exit code,
// so the error carries stderr, falls back to stdout, and always names the
// exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// Runs a script from a temp .ps1 with -File, so the script may hold any
// quote character and never appears on a command line. Values that came
// from params travel in `env` (read as $env:CW_…).
//
// The file carries a UTF-8 BOM, since Windows PowerShell 5.1 reads a
// BOM-less script as the ANSI code page. Output is forced to UTF-8 because
// 5.1 otherwise re-encodes native output to the OEM code page, and the host
// drops output that is not valid UTF-8. The trap reduces a terminating
// error to its message.
fn run_ps(script: string, env: Map[string, Value], timeout: int) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-visual-studio.ps1")
    let preamble = "$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\ntry {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\ntrap {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}\n"
    fs::write(file, "\u{FEFF}" + preamble + script)?
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\""
    let out = shell::run(cmd, Value::Map(#{ "env": Value::Map(env), "timeout": Value::Int(timeout) }))
    fs::delete_dir(dir)?
    out
}

// ---------------------------------------------------------------------
// Products, versions and ids
// ---------------------------------------------------------------------

fn products() -> List[string] { ["community", "professional", "enterprise", "build_tools", "test_agent"] }

fn product_param(params: Value) -> Result[string, string] {
    let p = param_str(params, "product", "community")
    if !products().contains(p) {
        return Err("invalid 'product' value '" + p + "' (expected :community, :professional, :enterprise, :build_tools or :test_agent)")
    }
    Ok(p)
}

// The vswhere -products id of a product symbol.
fn product_id(product: string) -> string {
    if product == "build_tools" { return "Microsoft.VisualStudio.Product.BuildTools" }
    if product == "test_agent" { return "Microsoft.VisualStudio.Product.TestAgent" }
    "Microsoft.VisualStudio.Product." + product.slice(0, 1).to_upper() + product.slice(1, product.len())
}

// The bootstrapper file name of a product symbol.
fn bootstrapper_name(product: string) -> string { "vs_" + product.replace("_", "") + ".exe" }

fn is_digits(s: string) -> bool {
    if s == "" { return false }
    s.chars().all(|c| c >= '0' && c <= '9')
}

// A vswhere version range: a bare major ("17", meaning [17.0,18.0)) or a
// range in vswhere's own interval syntax ("[16.0,17.0)", "[17.8,)").
fn version_range(v: string) -> Result[string, string] {
    let t = v.trim()
    if is_digits(t) {
        let major = t.parse_int().unwrap_or(0)
        return Ok("[" + str(major) + ".0," + str(major + 1) + ".0)")
    }
    let bad = Err("'version' must be a major version (15, 16, 17, 18) or a vswhere range such as [16.0,17.0), got '" + v + "'")
    if t.len() < 3 { return bad }
    let open = t.slice(0, 1)
    let close = t.slice(t.len() - 1, t.len())
    if !(open == "[" || open == "(") || !(close == "]" || close == ")") { return bad }
    let inner = t.slice(1, t.len() - 1)
    if !inner.contains(",") { return bad }
    if !inner.chars().all(|c| (c >= '0' && c <= '9') || c == '.' || c == ',') { return bad }
    Ok(t)
}

// The major version a range starts at, which picks the bootstrapper's
// release channel: [16.0,17.0) and [16.11,) start at 16. A range with no
// lower bound names no major.
fn range_major(range: string) -> Option[int] {
    let lower = range.slice(1, range.len() - 1).split(",").get(0).unwrap_or("")
    let major = lower.split(".").get(0).unwrap_or("")
    if !is_digits(major) { return None }
    major.parse_int()
}

// The Microsoft-hosted bootstrapper for a major version and product: the
// release channel for 2017 to 2022, the stable channel for 2026.
fn default_bootstrapper_url(major: int, product: string) -> Result[string, string] {
    if major < 15 || major > 18 {
        return Err("no Microsoft-hosted bootstrapper is known for Visual Studio major version " + str(major) + " (15 to 18 are); set 'bootstrapper'")
    }
    let channel = if major >= 18 { "stable" } else { "release" }
    Ok("https://aka.ms/vs/" + str(major) + "/" + channel + "/" + bootstrapper_name(product))
}

// A workload or component id, as it goes on the installer command line:
// letters, digits, '.', '-' and '_', not starting with '-'.
fn validate_id(label: string, id: string) -> Result[unit, string] {
    let allowed = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_"
    let ok = id != "" && !id.starts_with("-") && id.chars().all(|c| allowed.contains(str(c)))
    if !ok { return Err("'" + label + "' entries must be workload or component ids such as Microsoft.VisualStudio.Workload.MSBuildTools, got '" + id + "'") }
    Ok(())
}

// A value that is placed inside double quotes on the installer command
// line.
fn quotable(label: string, value: string) -> Result[unit, string] {
    if value.contains("\"") { return Err("'" + label + "' must not contain a double quote") }
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// Lower-cased, backslash-separated and without a trailing separator, for
// comparing paths the way NTFS does.
fn norm_path(p: string) -> string {
    let out = p.replace("/", "\\").to_lower().trim()
    while out.len() > 3 && out.ends_with("\\") { out = out.slice(0, out.len() - 1) }
    out
}

// ---------------------------------------------------------------------
// vswhere
// ---------------------------------------------------------------------

fn installer_dir() -> string {
    let pf86 = env::get("ProgramFiles(x86)").unwrap_or("C:\\Program Files (x86)")
    path::join(pf86, "Microsoft Visual Studio\\Installer")
}

// vswhere ships with the Visual Studio Installer, so a machine without it
// has no instances.
fn vswhere() -> Option[string] {
    let p = path::join(installer_dir(), "vswhere.exe")
    if fs::is_file(p) { return Some(p) }
    None
}

// Instances of `product_ids` (a vswhere -products value) within `range`
// ("" = any version), complete or not, as vswhere's JSON maps. With
// `packages`, each map carries every installed package under "packages".
fn instances(product_ids: string, range: string, packages: bool) -> Result[List[Value], string] {
    let none: List[Value] = []
    let exe = vswhere()
    if exe.is_none() { return Ok(none) }
    let cmd = "\"" + exe.unwrap() + "\" -all -prerelease -products " + product_ids + " -format json -utf8 -nologo"
    if range != "" { cmd = cmd + " -version " + range }
    if packages { cmd = cmd + " -include packages" }
    let out = shell::run(cmd, Value::Null)?
    if !out.success { return Err(failure("vswhere", out)) }
    let text = out.stdout.trim()
    if text == "" { return Ok(none) }
    let parsed = json::parse(text)?
    if let Some(items) = parsed.as_list() { return Ok(items) }
    Ok(none)
}

// The selected packages recorded for an instance: what was asked for with
// --add (and what --includeRecommended brought in), as opposed to what was
// pulled in as a dependency. Read from the instance's state.json.
fn state_file(instance_id: string) -> string {
    let pd = env::get("ProgramData").unwrap_or("C:\\ProgramData")
    path::join(pd, "Microsoft\\VisualStudio\\Packages\\_Instances\\" + instance_id + "\\state.json")
}

// A selectedPackages entry for a workload or component someone asked for
// (--add, or a tick in the installer UI), as opposed to one a product or
// another selection brought in.
fn is_explicit_selection(p: Value) -> bool {
    let t = get_str(p, "type").to_lower()
    (t == "workload" || t == "component") && get_str(p, "userSelectedState").to_lower() == "explicit"
}

fn selected_packages(instance_id: string) -> Result[List[Value], string] {
    let f = state_file(instance_id)
    let text = fs::read(f)?
    if text.starts_with("\u{FEFF}") { text = text.slice(1, text.len()) }
    let state = json::parse(text)?
    Ok(get_list(state, "selectedPackages"))
}

// ---------------------------------------------------------------------
// Running the installer
// ---------------------------------------------------------------------

// PowerShell that waits up to `secs` for every Visual Studio installer
// process to exit, and fails naming them when they do not. Two installer
// operations at once fail with exit 1001 or 1618, and an operation started
// by hand or by another tool would otherwise surface as that bare code.
fn wait_for_installers_ps(secs: int) -> string {
    "function Get-VsSetup {{\n" +
    "  $dir = Join-Path ${{env:ProgramFiles(x86)}} 'Microsoft Visual Studio\\Installer'\n" +
    "  @(Get-Process -ErrorAction SilentlyContinue | Where-Object {{\n" +
    "    $_.Name -match '^(vs_installer|vs_installershell|vs_installerservice|vs_setup_bootstrapper|vs_bootstrapper.*|vs_(community|professional|enterprise|buildtools|testagent))$' -or\n" +
    "    ($_.Name -eq 'setup' -and $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase))\n" +
    "  }})\n" +
    "}}\n" +
    "$deadline = (Get-Date).AddSeconds(" + str(secs) + ")\n" +
    "while (($busy = Get-VsSetup).Count -gt 0) {{\n" +
    "  if ((Get-Date) -gt $deadline) {{ throw ('another Visual Studio installer is still running after " + str(secs) + "s (' + (($busy | ForEach-Object {{ $_.Name + ' ' + $_.Id }}) -join ', ') + '); wait for it to finish or stop it') }}\n" +
    "  Start-Sleep -Seconds 10\n" +
    "}}\n"
}

// The installer's own explanation of an exit code, from its documentation.
fn exit_meaning(code: int) -> string {
    if code == 740 { return "elevation required" }
    if code == 1001 { return "a Visual Studio installer process is running" }
    if code == 1003 { return "Visual Studio is in use" }
    if code == 1602 || code == 5004 { return "the operation was canceled" }
    if code == 1618 { return "another installation is running" }
    if code == 5003 { return "the bootstrapper failed to download the installer" }
    if code == 5005 { return "the bootstrapper could not parse its command line" }
    if code == 5007 { return "the operation was blocked: the computer does not meet the requirements" }
    if code == 8006 { return "Visual Studio processes are running" }
    if code == 8010 { return "the operating system is not supported" }
    if code == -1073720687 { return "connectivity failure" }
    if code == -1073741510 { return "the installer was terminated" }
    ""
}

// The installer's logs (dd_bootstrapper_*, dd_client_*, dd_setup_*) go to
// the running account's temp directory, which for SYSTEM is
// C:\Windows\SystemTemp on current Windows and C:\Windows\Temp before it.
// Prints the newest dd_setup log (else any dd_ log) written since
// `since_ms`, and the lines of its _errors companion.
fn newest_log_ps() -> string {
    "$since = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$env:CW_SINCE).LocalDateTime.AddSeconds(-5)\n" +
    "$dirs = @($env:TEMP, [IO.Path]::GetTempPath(), (Join-Path $env:SystemRoot 'SystemTemp'), (Join-Path $env:SystemRoot 'Temp')) | Where-Object {{ $_ -and (Test-Path -LiteralPath $_) }} | Select-Object -Unique\n" +
    "$logs = @($dirs | ForEach-Object {{ Get-ChildItem -LiteralPath $_ -Filter 'dd_*.log' -File -ErrorAction SilentlyContinue }} | Where-Object {{ $_.LastWriteTime -ge $since -and $_.Name -notmatch '_errors\\.log$' }} | Sort-Object LastWriteTime)\n" +
    "$setup = @($logs | Where-Object {{ $_.Name -match '^dd_setup_\\d+\\.log$' }})\n" +
    "$pick = if ($setup.Count) {{ $setup[-1] }} elseif ($logs.Count) {{ $logs[-1] }} else {{ $null }}\n" +
    "if ($pick) {{\n" +
    "  'log: ' + $pick.FullName\n" +
    "  $err = $pick.FullName -replace '\\.log$', '_errors.log'\n" +
    "  if (Test-Path -LiteralPath $err) {{ Get-Content -LiteralPath $err -Tail 15 | Where-Object {{ $_.Trim() }} }}\n" +
    "}}\n"
}

// Runs a Visual Studio bootstrapper with `args` and waits for it (it is
// given --wait). The arguments travel in the environment so they are not
// re-quoted on the way. Exit 3010 and 1641 mean a reboot is needed; any
// other non-zero code is an error carrying the code's meaning, the newest
// dd_*.log path and its error lines.
//
// A bootstrapper that fails before the installer engine starts (no
// dd_setup log) is run once more: on a fresh machine it first fetches and
// updates the Visual Studio Installer, and a slow network makes that step
// fail with "Bootstrapper failed with known error" where a second run
// succeeds.
fn run_bootstrapper(exe: string, args: string, what: string, env: Map[string, Value]) -> Result[ApplyResult, string] {
    let attempt = 1
    loop {
        let since = time::now_millis()
        let out = run_bootstrapper_once(exe, args, what, env)?
        if out.code == 0 { return Ok(ApplyResult::Success) }
        if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
        let logs = run_ps(newest_log_ps(), #{ "CW_SINCE": Value::String(str(since)) }, 120)?
        let tail = logs.stdout.trim()
        let engine_ran = tail.contains("\\dd_setup_")
        let final = [740, 5005, 5007, 8010].contains(out.code)
        if attempt == 1 && !engine_ran && !final {
            log::warn(what + " failed in the bootstrapper (exit " + str(out.code) + ") before the installer started; running it once more")
            attempt = 2
            time::sleep(30000)
            continue
        }
        let msg = what + " failed (exit " + str(out.code) + ")"
        let meaning = exit_meaning(out.code)
        if meaning != "" { msg = msg + ": " + meaning }
        let detail = out.stderr.trim()
        if detail != "" { msg = msg + ": " + detail }
        if tail != "" { msg = msg + "\n" + tail } else { msg = msg + "\nno dd_*.log was written; look in the temp directory of the account config-weave runs as" }
        return Err(msg)
    }
    Err("unreachable")
}

fn run_bootstrapper_once(exe: string, args: string, what: string, env: Map[string, Value]) -> Result[CmdOutput, string] {
    let vars = env.clone()
    vars.insert("CW_EXE", Value::String(exe))
    vars.insert("CW_ARGS", Value::String(args))
    let script = wait_for_installers_ps(1800) +
        "$argLine = $env:CW_ARGS\n" +
        "$respDir = $null\n" +
        // A product key goes in a response file (--in) that only SYSTEM
        // and Administrators can read, never on the command line, and is
        // deleted once the bootstrapper exits.
        "if ($env:CW_PRODUCT_KEY) {{\n" +
        "  $respDir = Join-Path $env:ProgramData ('config-weave\\visual_studio\\response-' + [guid]::NewGuid().ToString('N'))\n" +
        "  $null = New-Item -ItemType Directory -Force -Path $respDir\n" +
        "  $acl = New-Object Security.AccessControl.DirectorySecurity\n" +
        "  $acl.SetAccessRuleProtection($true, $false)\n" +
        "  foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {{ $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))) }}\n" +
        "  Set-Acl -LiteralPath $respDir -AclObject $acl\n" +
        "  $resp = Join-Path $respDir 'response.json'\n" +
        "  [IO.File]::WriteAllText($resp, (ConvertTo-Json -Compress -InputObject @{{ productKey = $env:CW_PRODUCT_KEY }}))\n" +
        "  $argLine = $argLine + ' --in \"' + $resp + '\"'\n" +
        "}}\n" +
        "try {{ $p = Start-Process -FilePath $env:CW_EXE -ArgumentList $argLine -Wait -PassThru }}\n" +
        "finally {{ if ($respDir) {{ Remove-Item -LiteralPath $respDir -Recurse -Force -ErrorAction SilentlyContinue }} }}\n" +
        "exit $p.ExitCode\n"
    log::info(what + ": " + exe + " " + args)
    run_ps(script, vars, 14400)
}

fn is_url(src: string) -> bool {
    let l = src.to_lower()
    l.starts_with("http://") || l.starts_with("https://")
}

// Bootstrappers are kept under ProgramData, one directory per source, so a
// run never depends on a temp directory that is cleaned out.
fn cache_dir() -> string {
    let pd = env::get("ProgramData").unwrap_or("C:\\ProgramData")
    path::join(pd, "config-weave\\visual_studio")
}

// Checks a bootstrapper before anything runs it: it must carry a valid
// Authenticode signature, which a truncated or substituted download does
// not.
fn verify_signature(file: string) -> Result[unit, string] {
    let script = "$s = Get-AuthenticodeSignature -LiteralPath $env:CW_FILE\n" +
        "if ($s.Status -ne 'Valid') {{ throw ('signature status ' + $s.Status + ': ' + $s.StatusMessage) }}\n"
    let out = run_ps(script, #{ "CW_FILE": Value::String(file) }, 120)?
    if !out.success { return Err(failure("checking the signature of '" + file + "'", out)) }
    Ok(())
}

// The local bootstrapper to run. A URL is downloaded fresh every time
// (aka.ms links always name the newest bootstrapper) into the cache,
// retried up to three times by http::download, which renames only a
// complete download into place. It must then carry a valid signature, or
// it is deleted, so a failed or tampered download never runs. A local path
// is used as it is.
fn bootstrapper_file(src: string, product: string) -> Result[string, string] {
    if !is_url(src) {
        if !fs::is_file(src) { return Err("bootstrapper '" + src + "' does not exist") }
        verify_signature(src)?
        return Ok(src)
    }
    let dir = path::join(cache_dir(), hash::sha256(src).slice(0, 16))
    fs::mkdir(dir)?
    let f = path::join(dir, bootstrapper_name(product))
    log::info("downloading " + src)
    let n = http::download(src, f, Value::Map(#{ "timeout": Value::Int(600), "retries": Value::Int(3) }))?
    if n <= 0 {
        fs::delete(f).unwrap_or(())
        return Err("downloading the bootstrapper from " + src + " failed: the download was empty")
    }
    if let Err(e) = verify_signature(f) {
        fs::delete(f).unwrap_or(())
        return Err("the bootstrapper downloaded from " + src + " failed its check: " + e)
    }
    Ok(f)
}
