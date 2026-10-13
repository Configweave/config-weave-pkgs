// Helpers every windows_domain script shares: param access, credentials kept
// out of the script text, the DsRole membership probe, and reboot tracking.
use value
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
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

fn get_int(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(n) = v.as_int() { return n } }
    0
}

fn parse(text: string) -> Result[Value, string] { json::parse(text) }

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// A domain FQDN or NetBIOS name: letters, digits, '-' and '.', nothing that
// could reach a command line as anything else.
fn domain_name(label: string, value: string) -> Result[unit, string] {
    if value == "" { return Err("missing '" + label + "' parameter") }
    for c in value.chars() {
        let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.'
        if !ok { return Err("'" + label + "' is not a valid domain or workgroup name, got '" + value + "'") }
    }
    if value.starts_with("-") || value.starts_with(".") || value.ends_with(".") {
        return Err("'" + label + "' is not a valid domain or workgroup name, got '" + value + "'")
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Quoting and PowerShell
// ---------------------------------------------------------------------

// A PowerShell single-quoted literal. PowerShell also treats the curly
// quotes U+2018 to U+201B as single quotes, so they are doubled too.
fn ps_q(s: string) -> string {
    let out = s.replace("'", "''")
    for quote in ["\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"] {
        out = out.replace(quote, quote + quote)
    }
    "'" + out + "'"
}

fn ps_bool(b: bool) -> string { if b { "$true" } else { "$false" } }

// The error carries stderr, falls back to stdout, and names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// Run `script` with `secrets` as environment variables. A password is only
// ever read inside the script as $env:<NAME>, so it never appears in the
// script text, on a command line, or in the source line PowerShell 5.1
// echoes in its errors; a failure is reported as its message alone.
// Success exits 0 explicitly: the exit code would otherwise follow $? of
// the last statement, which a deliberately caught not-found leaves false.
fn ps_env(what: string, script: string, secrets: Map[string, Value]) -> Result[string, string] {
    let full = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; " +
        "try {{ " + script + "\nexit 0 }} catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}"
    let opts = if secrets.len() == 0 { Value::Null } else { Value::Map(#{ "env": Value::Map(secrets) }) }
    let out = shell::powershell(full, opts)?
    if !out.success { return Err(failure(what, out)) }
    Ok(out.stdout.trim())
}

fn ps(what: string, script: string) -> Result[string, string] { ps_env(what, script, #{}) }

// ---------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------

// The account given by credential_user/credential_password, or None when
// neither is set. Setting only one of them is an error, not a silent
// fall-back to the current account.
fn credential(params: Value) -> Result[Option[List[string]], string] {
    let user = param_str(params, "credential_user", "")
    let pw = param_str(params, "credential_password", "")
    single_line("credential_user", user)?
    if user == "" && pw == "" { return Ok(None) }
    if user == "" { return Err("'credential_password' is set but 'credential_user' is not; set both or neither") }
    if pw == "" { return Err("'credential_user' is set but 'credential_password' is not; set both or neither") }
    Ok(Some([user, pw]))
}

// PowerShell binding $cred to the credential, its password read from
// $env:CW_CRED_PW (see secrets_for).
fn cred_ps(user: string) -> string {
    "$cred = New-Object System.Management.Automation.PSCredential(" + ps_q(user) +
    ", (ConvertTo-SecureString $env:CW_CRED_PW -AsPlainText -Force)); "
}

// ---------------------------------------------------------------------
// Membership and pending reboots
// ---------------------------------------------------------------------

// PowerShell defining Get-CwDsRole, which returns this machine's role from
// DsRoleGetPrimaryDomainInformation: MachineRole (0-5, as
// Win32_ComputerSystem.DomainRole), the domain's NetBIOS and DNS names, and
// whether a promotion or demotion is waiting for its reboot.
fn dsrole_ps() -> string {
    "if (-not ('CwDsRole' -as [type])) {{ Add-Type -TypeDefinition @'\n" +
    "using System; using System.Runtime.InteropServices;\n" +
    "public static class CwDsRole {{\n" +
    "  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]\n" +
    "  struct Basic {{ public int MachineRole; public int Flags; public string Flat; public string Dns; public string Forest; public Guid DomainGuid; }}\n" +
    "  [DllImport(\"netapi32.dll\", CharSet = CharSet.Unicode)] static extern int DsRoleGetPrimaryDomainInformation(string server, int level, out IntPtr buffer);\n" +
    "  [DllImport(\"netapi32.dll\")] static extern void DsRoleFreeMemory(IntPtr buffer);\n" +
    "  public static object[] Get() {{\n" +
    "    IntPtr p; int rc = DsRoleGetPrimaryDomainInformation(null, 1, out p);\n" +
    "    if (rc != 0) throw new System.ComponentModel.Win32Exception(rc);\n" +
    "    Basic b = (Basic)Marshal.PtrToStructure(p, typeof(Basic)); DsRoleFreeMemory(p);\n" +
    "    rc = DsRoleGetPrimaryDomainInformation(null, 3, out p);\n" +
    "    if (rc != 0) throw new System.ComponentModel.Win32Exception(rc);\n" +
    "    int state = Marshal.ReadInt32(p); DsRoleFreeMemory(p);\n" +
    "    return new object[] {{ b.MachineRole, b.Flat ?? \"\", b.Dns ?? \"\", state == 2 }};\n" +
    "  }}\n" +
    "}}\n" +
    "'@ }}; " +
    "function Get-CwDsRole {{ $r = [CwDsRole]::Get(); [pscustomobject]@{{ role = [int]$r[0]; netbios = [string]$r[1]; dns = [string]$r[2]; role_reboot = [bool]$r[3] }} }}; "
}

// Where a resource records the boot it asked a reboot from. While the
// machine has not rebooted since, the change is not finished, and check
// reports RebootRequired rather than reading the half-applied state.
fn marker_key() -> string { "HKLM:\\SOFTWARE\\ConfigWeave\\windows_domain" }

fn boot_ps() -> string {
    "$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o'); "
}

// PowerShell setting $pending: a reboot this resource asked for has not
// happened yet, or Windows itself has a domain join or computer rename
// waiting for one.
fn pending_ps(resource: string) -> string {
    boot_ps() +
    "$mark = (Get-ItemProperty -Path '" + marker_key() + "' -Name " + ps_q(resource) + " -ErrorAction SilentlyContinue).'" + resource + "'; " +
    "$cn = 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\ComputerName'; " +
    "$renaming = (Get-ItemProperty \"$cn\\ActiveComputerName\").ComputerName -ne (Get-ItemProperty \"$cn\\ComputerName\").ComputerName; " +
    "$joining = Test-Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Netlogon\\JoinDomain'; " +
    "$pending = ($mark -eq $boot) -or $renaming -or $joining; "
}

// PowerShell recording that `resource` has asked for a reboot.
fn mark_ps(resource: string) -> string {
    boot_ps() +
    "New-Item -Path '" + marker_key() + "' -Force | Out-Null; " +
    "Set-ItemProperty -Path '" + marker_key() + "' -Name " + ps_q(resource) + " -Value $boot; "
}
