// Helpers every windows_account script shares: param access, validation,
// quoting, and running PowerShell with secrets kept out of the script text.
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

// An optional bool: None when the param was omitted, which means "unmanaged".
fn param_opt_bool(params: Value, key: string) -> Option[bool] {
    if let Some(v) = params.get(key) { return v.as_bool() }
    None
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

// ---------------------------------------------------------------------
// Validation (check and apply both call it, so check fails loudly too)
// ---------------------------------------------------------------------

fn require(params: Value, key: string) -> Result[string, string] {
    let v = param_str(params, key, "")
    if v == "" { return Err("missing '" + key + "' parameter") }
    Ok(v)
}

fn single_line(label: string, value: string) -> Result[unit, string] {
    if value.contains("\n") || value.contains("\r") { return Err("'" + label + "' must not contain a line break") }
    Ok(())
}

// A SAM account or group name. Windows forbids these characters in one, and
// the *?[] among them are wildcards to Get-LocalUser/-LocalGroup -Name, so a
// name holding them could select other accounts.
fn account_name(label: string, value: string) -> Result[unit, string] {
    if value == "" { return Err("missing '" + label + "' parameter") }
    for c in ["\"", "/", "\\", "[", "]", ":", ";", "|", "=", ",", "+", "*", "?", "<", ">"] {
        if value.contains(c) { return Err("'" + label + "' must not contain '" + c + "', got '" + value + "'") }
    }
    if value.trim() != value { return Err("'" + label + "' must not start or end with whitespace") }
    if value.ends_with(".") { return Err("'" + label + "' must not end with '.'") }
    single_line(label, value)
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

// Many tools report failures on stdout, so the error carries stderr, falls
// back to stdout, and always names the exit code.
fn failure(what: string, out: CmdOutput) -> string {
    let detail = out.stderr.trim()
    if detail == "" { detail = out.stdout.trim() }
    if detail == "" { return what + " failed (exit " + str(out.code) + ")" }
    what + " failed (exit " + str(out.code) + "): " + detail
}

fn preamble() -> string {
    "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; " +
    "try {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}; "
}

// Report a failure as its message alone. PowerShell 5.1 would otherwise
// print the offending source line and a position marker after it. Success
// exits 0 explicitly: the exit code would otherwise follow $? of the last
// statement, which an exception caught on purpose (a not-found probe)
// leaves false.
fn wrap(script: string) -> string {
    "try {{ " + script + "\nexit 0 }} catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}"
}

// Run `script`, passing `secrets` as environment variables. A password is
// only ever read inside the script as $env:<NAME>, so it never appears in the
// script text, on a command line, or in the source line PowerShell 5.1 echoes
// back in its error messages.
fn ps_env(what: string, script: string, secrets: Map[string, Value]) -> Result[string, string] {
    let opts = if secrets.len() == 0 { Value::Null } else { Value::Map(#{ "env": Value::Map(secrets) }) }
    let out = shell::powershell(preamble() + wrap(script), opts)?
    if !out.success { return Err(failure(what, out)) }
    Ok(out.stdout.trim())
}

fn ps(what: string, script: string) -> Result[string, string] {
    ps_env(what, script, #{})
}

// PowerShell that binds $<var> to a SecureString read from $env:<env_name>.
fn secure_from_env(var: string, env_name: string) -> string {
    "$" + var + " = ConvertTo-SecureString $env:" + env_name + " -AsPlainText -Force; "
}

// ---------------------------------------------------------------------
// Password verification
// ---------------------------------------------------------------------

// PowerShell defining Test-CwPassword($user, $domain, $password), which tries
// a network logon and reports whether the password is right:
//   'OK'     - the password is right (the logon may still have been refused
//              for a reason that comes after the password check, such as a
//              disabled or expired account or a missing logon right)
//   'BAD'    - the password is wrong
//   'LOCKED' - the account is locked out, so the password cannot be tested
// A wrong password counts toward the account lockout threshold, like any
// failed logon.
fn logon_test_ps() -> string {
    "if (-not ('CwLogon' -as [type])) {{ Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; " +
    "public static class CwLogon {{ " +
    "[DllImport(\"advapi32.dll\", SetLastError = true, CharSet = CharSet.Unicode)] " +
    "public static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token); " +
    "[DllImport(\"kernel32.dll\")] public static extern bool CloseHandle(IntPtr h); }}' }}; " +
    "function Test-CwPassword($user, $domain, $password) {{ " +
    "$t = [IntPtr]::Zero; " +
    "if ([CwLogon]::LogonUser($user, $domain, $password, 3, 0, [ref]$t)) {{ [void][CwLogon]::CloseHandle($t); return 'OK' }}; " +
    "$e = [Runtime.InteropServices.Marshal]::GetLastWin32Error(); " +
    // 1326 logon failure (bad user or password); 1909 locked out. The rest
    // (1327 restriction, 1328 hours, 1329 workstation, 1330 password expired,
    // 1331 disabled, 1385/1792 logon type not granted, 1793 account expired,
    // 1907 must change password) are only reported once the password matched.
    "if ($e -eq 1326) {{ return 'BAD' }}; if ($e -eq 1909) {{ return 'LOCKED' }}; " +
    "if (@(1327,1328,1329,1330,1331,1385,1792,1793,1907) -contains $e) {{ return 'OK' }}; " +
    "throw ('LogonUser failed with Win32 error ' + $e) }}; "
}

fn password_state_err(state: string, who: string) -> Result[bool, string] {
    if state == "OK" { return Ok(true) }
    if state == "BAD" { return Ok(false) }
    if state == "LOCKED" { return Err("cannot verify the password of '" + who + "': the account is locked out") }
    Err("unexpected password probe result for '" + who + "': " + state)
}

fn parse_json(text: string) -> Result[Value, string] { json::parse(text) }

// ---------------------------------------------------------------------
// Active Directory
// ---------------------------------------------------------------------

// PowerShell that loads the ActiveDirectory module (failing with a clear
// message when RSAT is missing) and binds $srv, a splat every AD cmdlet
// takes: empty, or @{ Server = <server> } when the 'server' param is set.
fn ad_prelude(params: Value) -> Result[string, string] {
    let server = param_str(params, "server", "")
    single_line("server", server)?
    let bind = if server != "" { "$srv = @{{ Server = " + ps_q(server) + " }}; " } else { "$srv = @{{}}; " }
    Ok("if (-not (Get-Module -ListAvailable ActiveDirectory)) {{ throw 'the ActiveDirectory PowerShell module is required (install RSAT-AD-PowerShell)' }}; " +
        "Import-Module ActiveDirectory -Verbose:$false; " + bind)
}

// An LDAP filter assertion value (RFC 4515): \, *, (, ) and NUL escaped.
fn ldap_escape(s: string) -> string {
    s.replace("\\", "\\5c").replace("*", "\\2a").replace("(", "\\28").replace(")", "\\29").replace("\u{0}", "\\00")
}

// PowerShell binding $parent to the DN of the container holding the object
// whose DN is in $dn. The first RDN ends at the first unescaped comma.
fn parent_dn_ps() -> string {
    "$parent = $dn -replace '^(?:[^,\\\\]|\\\\.)+,', ''; "
}

// PowerShell setting $ouOk: true when ou_path is unset, or when the object
// already sits in it. The OU is read back from AD, so spelling and case
// differences do not count, and a missing OU fails loudly.
fn ou_match_ps(ou: string) -> string {
    if ou == "" { return "$ouOk = $true; " }
    parent_dn_ps() +
    "$ouObj = Get-ADObject @srv -Identity " + ps_q(ou) + "; " +
    "$ouOk = ($parent -eq $ouObj.DistinguishedName); "
}
