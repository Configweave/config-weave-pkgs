use value
use fs
use json
use log
use registry
use service
use common

// Where the last pushed password_revision is recorded, per service. The
// password itself cannot be read back from the SCM, so the revision is what
// check compares.
fn revision_key(name: string) -> string { "HKLM\\SOFTWARE\\ConfigWeave\\windows_service\\" + name }

// :unmanaged means "do not look at this aspect": it is what lets one
// resource register a service without also deciding whether it runs.
fn desired_state(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "state", "unmanaged")
    if s == "running" || s == "stopped" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'state' value '" + s + "' (expected :running, :stopped or :unmanaged)")
}

// :automatic and :automatic_delayed are different states: neither matches a
// service set to the other.
fn desired_startup(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "startup", "unmanaged")
    if s == "automatic" || s == "automatic_delayed" || s == "manual" || s == "disabled" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'startup' value '" + s + "' (expected :automatic, :automatic_delayed, :manual, :disabled or :unmanaged)")
}

// A `duration` param arrives as base nanoseconds.
fn timeout_secs(params: Value) -> int {
    let secs = common::param_int(params, "timeout", 60 * 1000000000) / 1000000000
    if secs < 1 { 1 } else { secs }
}

// Everything check() and apply() validate up front, so check fails loudly too.
fn validate(params: Value) -> Result[unit, string] {
    let name = common::param_str(params, "name", "")
    common::validate_name(name)?
    common::want_present(params)?
    let st = desired_state(params)?
    let su = desired_startup(params)?
    if st == "running" && su == "disabled" {
        return Err("service '" + name + "': state = :running cannot hold with startup = :disabled (a disabled service cannot be started)")
    }
    let p = common::param_str(params, "path", "")
    if p.contains("\"") {
        return Err("'path' must be the bare executable path without quotes; the resource quotes it. Put arguments in 'arguments'")
    }
    common::single_line("path", p)?
    // A pre-split `path` still carrying its arguments would be registered as
    // one quoted (and so nonexistent) executable.
    if p != "" && !fs::is_file(p) && (p.contains(" -") || p.contains(" /")) {
        return Err("'path' looks like it includes arguments ('" + p + "'); since the path/arguments split, put the executable in 'path' and the rest in 'arguments'")
    }
    common::single_line("arguments", common::param_str(params, "arguments", ""))?
    common::single_line("display_name", common::param_str(params, "display_name", ""))?
    common::single_line("user", common::param_str(params, "user", ""))?
    common::single_line("password_revision", common::param_str(params, "password_revision", ""))?
    if common::param_str(params, "password", "") != "" && common::param_str(params, "user", "") == "" {
        return Err("'password' is set but 'user' is not; name the account the password belongs to")
    }
    Ok(())
}

// Resolves an account name to its SID the way the SCM stores it: LocalSystem
// and NT AUTHORITY\SYSTEM are one account, and .\name means this computer.
fn sid_fn() -> string {
    "function CwSid([string]$a) {{\n" +
    "  if ($a -eq '') {{ return '' }}\n" +
    "  if ($a -ieq 'LocalSystem' -or $a -ieq '.\\LocalSystem') {{ return 'S-1-5-18' }}\n" +
    "  if ($a.StartsWith('.\\')) {{ $a = $env:COMPUTERNAME + $a.Substring(1) }}\n" +
    "  try {{ return (New-Object System.Security.Principal.NTAccount($a)).Translate([System.Security.Principal.SecurityIdentifier]).Value }} catch {{ return '' }}\n" +
    "}}\n"
}

// LsaEnumerateAccountRights / LsaAddAccountRights, for SeServiceLogonRight.
// Neither New-Service nor Win32_Service.Change grants the right (only the
// services console does), and without it the service fails to start with
// error 1069.
fn lsa_type() -> string {
    "if (-not ('CwLsa' -as [type])) {{ Add-Type -TypeDefinition @'\n" +
    "using System;\n" +
    "using System.Runtime.InteropServices;\n" +
    "using System.Security.Principal;\n" +
    "public static class CwLsa {{\n" +
    "  [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING {{ public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }}\n" +
    "  [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES {{ public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }}\n" +
    "  [DllImport(\"advapi32.dll\")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, int access, out IntPtr handle);\n" +
    "  [DllImport(\"advapi32.dll\")] static extern uint LsaAddAccountRights(IntPtr handle, byte[] sid, LSA_UNICODE_STRING[] rights, int count);\n" +
    "  [DllImport(\"advapi32.dll\")] static extern uint LsaEnumerateAccountRights(IntPtr handle, byte[] sid, out IntPtr rights, out int count);\n" +
    "  [DllImport(\"advapi32.dll\")] static extern uint LsaFreeMemory(IntPtr p);\n" +
    "  [DllImport(\"advapi32.dll\")] static extern uint LsaClose(IntPtr h);\n" +
    "  [DllImport(\"advapi32.dll\")] static extern int LsaNtStatusToWinError(uint status);\n" +
    "  static IntPtr Open() {{\n" +
    "    LSA_OBJECT_ATTRIBUTES a = new LSA_OBJECT_ATTRIBUTES();\n" +
    "    IntPtr h; uint st = LsaOpenPolicy(IntPtr.Zero, ref a, 0x00000800 | 0x00000010, out h);\n" +
    "    if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));\n" +
    "    return h;\n" +
    "  }}\n" +
    "  static byte[] Sid(string sid) {{ SecurityIdentifier s = new SecurityIdentifier(sid); byte[] b = new byte[s.BinaryLength]; s.GetBinaryForm(b, 0); return b; }}\n" +
    "  public static bool Has(string sid, string right) {{\n" +
    "    IntPtr h = Open();\n" +
    "    try {{\n" +
    "      IntPtr p; int n; uint st = LsaEnumerateAccountRights(h, Sid(sid), out p, out n);\n" +
    "      if (st == 0xC0000034) return false;\n" +
    "      if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));\n" +
    "      try {{\n" +
    "        int size = Marshal.SizeOf(typeof(LSA_UNICODE_STRING));\n" +
    "        for (int i = 0; i < n; i++) {{\n" +
    "          LSA_UNICODE_STRING u = (LSA_UNICODE_STRING)Marshal.PtrToStructure(new IntPtr(p.ToInt64() + i * size), typeof(LSA_UNICODE_STRING));\n" +
    "          if (Marshal.PtrToStringUni(u.Buffer, u.Length / 2) == right) return true;\n" +
    "        }}\n" +
    "        return false;\n" +
    "      }} finally {{ LsaFreeMemory(p); }}\n" +
    "    }} finally {{ LsaClose(h); }}\n" +
    "  }}\n" +
    "  public static void Add(string sid, string right) {{\n" +
    "    IntPtr h = Open();\n" +
    "    try {{\n" +
    "      LSA_UNICODE_STRING u = new LSA_UNICODE_STRING();\n" +
    "      u.Buffer = Marshal.StringToHGlobalUni(right); u.Length = (ushort)(right.Length * 2); u.MaximumLength = (ushort)(u.Length + 2);\n" +
    "      try {{\n" +
    "        uint st = LsaAddAccountRights(h, Sid(sid), new LSA_UNICODE_STRING[] {{ u }}, 1);\n" +
    "        if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));\n" +
    "      }} finally {{ Marshal.FreeHGlobal(u.Buffer); }}\n" +
    "    }} finally {{ LsaClose(h); }}\n" +
    "  }}\n" +
    "}}\n" +
    "'@ }}\n"
}

// LocalSystem, LocalService, NetworkService and the NT SERVICE virtual
// accounts can log on as a service without an explicit grant.
fn builtin_sid(sid: string) -> bool {
    sid == "S-1-5-18" || sid == "S-1-5-19" || sid == "S-1-5-20" || sid.starts_with("S-1-5-80-")
}

// One read of everything check compares. Win32_Service is matched by its
// exact Name (WQL '=' compares case-insensitively, like the SCM), never by
// Get-Service's wildcard-and-display-name matching.
fn query(params: Value) -> Result[Value, string] {
    let user = common::param_str(params, "user", "")
    let script = sid_fn() +
        "$n = $env:CW_NAME\n" +
        "$f = \"Name='\" + $n.Replace('\\', '\\\\').Replace(\"'\", \"\\'\") + \"'\"\n" +
        "$s = Get-CimInstance -ClassName Win32_Service -Filter $f\n" +
        "$wantSid = CwSid $env:CW_USER\n" +
        "$wantExe = [Environment]::ExpandEnvironmentVariables([string]$env:CW_PATH)\n" +
        "if (-not $s) {{ [pscustomobject]@{{ exists = $false; want_sid = $wantSid; want_exe = $wantExe }} | ConvertTo-Json -Compress; exit 0 }}\n" +
        "$k = Get-ItemProperty -LiteralPath ('HKLM:\\SYSTEM\\CurrentControlSet\\Services\\' + $s.Name) -ErrorAction SilentlyContinue\n" +
        "$right = $true\n" +
        "if ($env:CW_CHECK_RIGHT -eq '1' -and $wantSid -ne '') {{\n" + lsa_type() + "  $right = [CwLsa]::Has($wantSid, 'SeServiceLogonRight') }}\n" +
        "[pscustomobject]@{{\n" +
        "  exists = $true; name = [string]$s.Name; display_name = [string]$s.DisplayName; description = [string]$s.Description\n" +
        "  path_name = [Environment]::ExpandEnvironmentVariables([string]$s.PathName)\n" +
        "  start_name = [string]$s.StartName; sid = (CwSid ([string]$s.StartName))\n" +
        "  state = [string]$s.State; delete_pending = ($k -and $k.DeleteFlag -eq 1)\n" +
        "  want_sid = $wantSid; want_exe = $wantExe; logon_right = $right\n" +
        "}} | ConvertTo-Json -Compress\n"
    let check_right = if user != "" { "1" } else { "0" }
    let out = common::run_ps(script, #{
        "CW_NAME": Value::String(common::param_str(params, "name", "")),
        "CW_USER": Value::String(user),
        "CW_PATH": Value::String(common::param_str(params, "path", "")),
        "CW_CHECK_RIGHT": Value::String(check_right)
    })?
    if !out.success { return Err(common::failure("querying service '" + common::param_str(params, "name", "") + "'", out)) }
    json::parse(out.stdout.trim())
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

// Win32_Service.State ("Running", "Stop Pending", ...) in service::status's
// spelling.
fn current_state(q: Value) -> string { get_str(q, "state").to_lower().replace(" ", "_") }

// The ImagePath this resource writes: the executable always quoted, so a
// path with a space can never be resolved as a shorter, hijackable path.
fn image_path(params: Value) -> string {
    let args = common::param_str(params, "arguments", "").trim()
    let quoted = "\"" + common::param_str(params, "path", "") + "\""
    if args == "" { quoted } else { quoted + " " + args }
}

// Whether the registered ImagePath is exactly the wanted quoted executable
// plus arguments. The executable compares case-insensitively, as Windows
// resolves it; the arguments compare exactly. An unquoted ImagePath always
// drifts, which is what rewrites a legacy unquoted path.
fn path_matches(params: Value, q: Value) -> bool {
    let cur = get_str(q, "path_name").trim()
    if !cur.starts_with("\"") { return false }
    let rest = cur.slice(1, cur.len())
    let end = rest.find("\"")
    if end.is_none() { return false }
    let e = end.unwrap_or(0)
    let exe = rest.slice(0, e)
    let args = rest.slice(e + 1, rest.len()).trim()
    exe.to_lower() == get_str(q, "want_exe").to_lower() && args == common::param_str(params, "arguments", "").trim()
}

fn recorded_revision(name: string) -> Result[string, string] {
    if let Some(v) = registry::read(revision_key(name), "PasswordRevision")? { return Ok(v.as_string().unwrap_or("")) }
    Ok("")
}

// The configuration drift on an existing service, as the list of params
// that differ. Empty means converged (state is compared separately).
fn config_drift(params: Value, q: Value) -> Result[List[string], string] {
    let name = common::param_str(params, "name", "")
    let drift: List[string] = []
    if common::param_str(params, "path", "") != "" && !path_matches(params, q) { drift.push("path") }
    let display = common::param_str(params, "display_name", "")
    if display != "" && get_str(q, "display_name") != display { drift.push("display_name") }
    let desc = common::param_str(params, "description", "")
    if desc != "" && get_str(q, "description") != desc { drift.push("description") }
    let user = common::param_str(params, "user", "")
    if user != "" {
        let want_sid = get_str(q, "want_sid")
        if want_sid == "" || want_sid != get_str(q, "sid") { drift.push("user") }
        if want_sid != "" && !builtin_sid(want_sid) && !get_bool(q, "logon_right") { drift.push("logon_right") }
        let rev = common::param_str(params, "password_revision", "")
        if rev != "" && recorded_revision(name)? != rev { drift.push("password_revision") }
    }
    let su = desired_startup(params)?
    if su != "unmanaged" && service::startup(name)? != su { drift.push("startup") }
    Ok(drift)
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let name = common::param_str(params, "name", "")
    let q = query(params)?
    let exists = get_bool(q, "exists")
    if !common::want_present(params)? {
        if !exists { return Ok(CheckResult::AlreadyConfigured) }
        // Marked for deletion and stopped: the SCM removes it as soon as the
        // last open handle closes, and nothing more can be done to it.
        if get_bool(q, "delete_pending") && current_state(q) == "stopped" {
            log::warn("service '" + name + "' is marked for deletion; it disappears once every open handle to it closes (services.msc, Event Viewer) or at reboot")
            return Ok(CheckResult::AlreadyConfigured)
        }
        return Ok(CheckResult::NotConfigured)
    }
    if !exists {
        if common::param_str(params, "path", "") == "" {
            return Err("service '" + name + "' does not exist and no 'path' was given to create it")
        }
        return Ok(CheckResult::NotConfigured)
    }
    if get_bool(q, "delete_pending") { return Ok(CheckResult::NotConfigured) }
    let user = common::param_str(params, "user", "")
    if user != "" && get_str(q, "want_sid") == "" {
        // The account may be created by an earlier step of this run.
        log::warn("service '" + name + "': account '" + user + "' cannot be resolved to a SID")
        return Ok(CheckResult::NotConfigured)
    }
    if !config_drift(params, q)?.is_empty() { return Ok(CheckResult::NotConfigured) }
    // Pending states and paused count as not yet configured; apply waits
    // them out and drives the service to the target.
    let st = desired_state(params)?
    if st != "unmanaged" && current_state(q) != st { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

// ---------------------------------------------------------------------
// State changes. service::start_with/stop_with wait out pending states,
// resume a paused service and wait for the target state, up to `timeout`.
// ---------------------------------------------------------------------

fn wait_opts(secs: int) -> Value { Value::Map(#{ "timeout": Value::Int(secs) }) }

fn sc(args: string, name: string, what: string) -> Result[CmdOutput, string] {
    // Stop would turn sc.exe's own failure into a PowerShell error and lose
    // the exit code; sc.exe reports on stdout.
    let out = common::run_ps("$ErrorActionPreference = 'Continue'; $o = & sc.exe " + args + " | Out-String; Write-Output $o; exit $LASTEXITCODE", #{ "CW_NAME": Value::String(name) })?
    if !out.success && what != "" { return Err(common::failure(what, out)) }
    Ok(out)
}

fn drive_to(name: string, target: string, secs: int) -> Result[unit, string] {
    if target == "running" { service::start_with(name, wait_opts(secs)) } else { service::stop_with(name, wait_opts(secs)) }
}

// ---------------------------------------------------------------------
// apply
// ---------------------------------------------------------------------

fn remove(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    let secs = timeout_secs(params)
    let q = query(params)?
    if !get_bool(q, "exists") { return Ok(ApplyResult::Success) }
    // Stop first and wait: deleting a running service only marks it for
    // deletion, and the next run would meet error 1072.
    let stopped = service::stop_with(name, wait_opts(secs))
    // A service already marked for deletion vanishes the moment it stops, so
    // the wait loses it.
    if stopped.is_err() && get_bool(query(params)?, "exists") { return Err(stopped.unwrap_err()) }
    if !get_bool(q, "delete_pending") {
        let out = sc("delete $env:CW_NAME", name, "")?
        if out.code == 1072 {
            log::warn("service '" + name + "' was already marked for deletion; it disappears once every open handle to it closes (services.msc, Event Viewer) or at reboot")
        } else if out.code != 0 && out.code != 1060 {
            return Err(common::failure("sc.exe delete " + name, out))
        }
    }
    if registry::key_exists(revision_key(name))? { registry::delete_key(revision_key(name))? }
    Ok(ApplyResult::Success)
}

fn ps_startup_type(startup: string) -> string {
    if startup == "manual" { return "Manual" }
    if startup == "disabled" { return "Disabled" }
    "Automatic"
}

fn create(params: Value, su: string) -> Result[unit, string] {
    let name = common::param_str(params, "name", "")
    let user = common::param_str(params, "user", "")
    // New-Service requires a startup type, so :unmanaged creates the service
    // Automatic and then leaves it alone. Delayed start is set afterwards.
    let create_type = ps_startup_type(if su == "unmanaged" { "automatic" } else { su })
    let script = "$p = @{{ Name = $env:CW_NAME; BinaryPathName = $env:CW_BINPATH; StartupType = '" + create_type + "' }}\n" +
        "if ([string]$env:CW_DISPLAY -ne '') {{ $p.DisplayName = $env:CW_DISPLAY }}\n" +
        "if ([string]$env:CW_DESC -ne '') {{ $p.Description = $env:CW_DESC }}\n" +
        "if ([string]$env:CW_USER -ne '') {{\n" +
        // Built-in accounts have no password; PSCredential still needs a
        // (then empty) SecureString.
        "  $sec = if ([string]$env:CW_SECRET -ne '') {{ ConvertTo-SecureString $env:CW_SECRET -AsPlainText -Force }} else {{ New-Object System.Security.SecureString }}\n" +
        "  $p.Credential = New-Object System.Management.Automation.PSCredential($env:CW_USER, $sec)\n" +
        "}}\n" +
        "New-Service @p | Out-Null\n"
    let out = common::run_ps(script, #{
        "CW_NAME": Value::String(name),
        "CW_BINPATH": Value::String(image_path(params)),
        "CW_DISPLAY": Value::String(common::param_str(params, "display_name", "")),
        "CW_DESC": Value::String(common::param_str(params, "description", "")),
        "CW_USER": Value::String(user),
        "CW_SECRET": Value::String(common::param_str(params, "password", ""))
    })?
    if !out.success { return Err(common::failure("creating service '" + name + "'", out)) }
    Ok(())
}

// Win32_Service.Change for the fields only it can set (ImagePath, display
// name, account). Each argument is passed only when it is being changed.
fn change(params: Value, set_path: bool, set_display: bool, set_account: bool) -> Result[unit, string] {
    let name = common::param_str(params, "name", "")
    let script = "$n = $env:CW_NAME\n" +
        "$f = \"Name='\" + $n.Replace('\\', '\\\\').Replace(\"'\", \"\\'\") + \"'\"\n" +
        "$s = Get-CimInstance -ClassName Win32_Service -Filter $f\n" +
        "$a = @{{}}\n" +
        "if ($env:CW_SET_PATH -eq '1') {{ $a.PathName = $env:CW_BINPATH }}\n" +
        "if ($env:CW_SET_DISPLAY -eq '1') {{ $a.DisplayName = $env:CW_DISPLAY }}\n" +
        "if ($env:CW_SET_ACCOUNT -eq '1') {{ $a.StartName = $env:CW_USER; $a.StartPassword = [string]$env:CW_SECRET }}\n" +
        "$r = Invoke-CimMethod -InputObject $s -MethodName Change -Arguments $a\n" +
        "if ($r.ReturnValue -ne 0) {{ throw ('Win32_Service.Change returned ' + $r.ReturnValue) }}\n"
    let out = common::run_ps(script, #{
        "CW_NAME": Value::String(name),
        "CW_SET_PATH": Value::String(if set_path { "1" } else { "0" }),
        "CW_BINPATH": Value::String(image_path(params)),
        "CW_SET_DISPLAY": Value::String(if set_display { "1" } else { "0" }),
        "CW_DISPLAY": Value::String(common::param_str(params, "display_name", "")),
        "CW_SET_ACCOUNT": Value::String(if set_account { "1" } else { "0" }),
        "CW_USER": Value::String(common::param_str(params, "user", "")),
        "CW_SECRET": Value::String(common::param_str(params, "password", ""))
    })?
    if !out.success { return Err(common::failure("reconfiguring service '" + name + "'", out)) }
    Ok(())
}

fn set_description(name: string, desc: string) -> Result[unit, string] {
    let out = common::run_ps("Set-Service -Name $env:CW_NAME -Description $env:CW_DESC", #{
        "CW_NAME": Value::String(name),
        "CW_DESC": Value::String(desc)
    })?
    if !out.success { return Err(common::failure("setting the description of service '" + name + "'", out)) }
    Ok(())
}

fn grant_logon_right(name: string, sid: string) -> Result[unit, string] {
    let out = common::run_ps(lsa_type() + "[CwLsa]::Add($env:CW_SID, 'SeServiceLogonRight')", #{ "CW_SID": Value::String(sid) })?
    if !out.success { return Err(common::failure("granting SeServiceLogonRight for service '" + name + "'", out)) }
    Ok(())
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    if !common::want_present(params)? { return remove(params) }
    let name = common::param_str(params, "name", "")
    let secs = timeout_secs(params)
    let su = desired_startup(params)?
    let st = desired_state(params)?
    let q = query(params)?
    if get_bool(q, "exists") && get_bool(q, "delete_pending") {
        return Err("service '" + name + "' is marked for deletion (error 1072); it can be created again once every open handle to it closes (services.msc, Event Viewer) or after a reboot")
    }
    let created = false
    if !get_bool(q, "exists") {
        if common::param_str(params, "path", "") == "" {
            return Err("service '" + name + "' does not exist and no 'path' was given to create it")
        }
        create(params, su)?
        created = true
        q = query(params)?
    }
    let user = common::param_str(params, "user", "")
    if user != "" && get_str(q, "want_sid") == "" {
        return Err("service '" + name + "': account '" + user + "' cannot be resolved to a SID")
    }
    let drift = config_drift(params, q)?
    // A changed account always needs its password pushed with it; a changed
    // revision pushes the password alone.
    let set_account = drift.contains("user") || drift.contains("password_revision")
    if drift.contains("path") || drift.contains("display_name") || set_account {
        change(params, drift.contains("path"), drift.contains("display_name"), set_account)?
    }
    if drift.contains("description") { set_description(name, common::param_str(params, "description", ""))? }
    if drift.contains("logon_right") { grant_logon_right(name, get_str(q, "want_sid"))? }
    let rev = common::param_str(params, "password_revision", "")
    if user != "" && rev != "" && (set_account || created) {
        registry::write(revision_key(name), "PasswordRevision", Value::String(rev), "sz")?
    }
    // set_startup(:automatic) also clears the delayed-start flag.
    if drift.contains("startup") { service::set_startup(name, su)? }
    // ImagePath and account changes only take effect at the next start, so a
    // service meant to be running is restarted onto the new configuration.
    let restart_needed = !created && (drift.contains("path") || set_account)
    let cur = current_state(q)
    if restart_needed && cur != "stopped" {
        if st == "running" {
            service::restart(name, wait_opts(secs))?
        } else if st == "unmanaged" {
            log::warn("service '" + name + "' is running; its new path or account takes effect at its next start")
        }
    }
    if st != "unmanaged" { drive_to(name, st, secs)? }
    Ok(ApplyResult::Success)
}
