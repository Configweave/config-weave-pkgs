use value
use fs
use path
use log
use shell
use sys
use common

// Windows rejects a component whose processorArchitecture does not match the
// image, silently dropping every setting in it, so :auto takes the running
// machine's architecture.
fn architecture(params: Value) -> Result[string, string] {
    let a = common::param_str(params, "architecture", "auto")
    if a == "amd64" || a == "arm64" || a == "x86" { return Ok(a) }
    if a != "auto" { return Err("invalid 'architecture' value '" + a + "' (expected :auto, :amd64, :arm64 or :x86)") }
    let host = sys::arch()
    if host == "x86_64" { return Ok("amd64") }
    if host == "aarch64" { return Ok("arm64") }
    if host == "x86" { return Ok("x86") }
    Err("cannot map this machine's architecture '" + host + "' to an unattend processorArchitecture; set 'architecture'")
}

fn el(name: string, body: string) -> string { "<" + name + ">" + body + "</" + name + ">" }

fn component(arch: string, name: string, body: string) -> string {
    "    <component name=\"" + name + "\" processorArchitecture=\"" + arch + "\"" +
    " publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">\n" +
    body + "    </component>\n"
}

// HideLocalAccountScreen is only emitted when the file sets the
// Administrator password: hiding the screen with no account defined leaves
// OOBE with no account to sign in to.
fn oobe_block(has_account: bool) -> string {
    let local = if has_account { "        " + el("HideLocalAccountScreen", "true") + "\n" } else { "" }
    "      <OOBE>\n" +
    "        " + el("HideEULAPage", "true") + "\n" +
    local +
    "        " + el("HideOEMRegistrationScreen", "true") + "\n" +
    "        " + el("HideOnlineAccountScreens", "true") + "\n" +
    "        " + el("HideWirelessSetupInOOBE", "true") + "\n" +
    "        " + el("ProtectYourPC", "3") + "\n" +
    "      </OOBE>\n"
}

fn sync_command(order: int, cmd: string) -> string {
    "        <SynchronousCommand wcm:action=\"add\">\n" +
    "          " + el("Order", str(order)) + "\n" +
    "          " + el("CommandLine", common::xml_esc(cmd)) + "\n" +
    "        </SynchronousCommand>\n"
}

fn first_logon_xml(cmds: List[string]) -> string {
    let body = ""
    for i in 0..cmds.len() { body = body + sync_command(i + 1, cmds[i]) }
    "      <FirstLogonCommands>\n" + body + "      </FirstLogonCommands>\n"
}

fn intl_component(params: Value, arch: string) -> string {
    let il = common::param_str(params, "input_locale", "")
    let sl = common::param_str(params, "system_locale", "")
    let ul = common::param_str(params, "ui_language", "")
    let us = common::param_str(params, "user_locale", "")
    let o_il = if il != "" { "      " + el("InputLocale", common::xml_esc(il)) + "\n" } else { "" }
    let o_sl = if sl != "" { "      " + el("SystemLocale", common::xml_esc(sl)) + "\n" } else { "" }
    let o_ul = if ul != "" { "      " + el("UILanguage", common::xml_esc(ul)) + "\n" } else { "" }
    let o_us = if us != "" { "      " + el("UserLocale", common::xml_esc(us)) + "\n" } else { "" }
    let body = o_il + o_sl + o_ul + o_us
    if body == "" { return "" }
    component(arch, "Microsoft-Windows-International-Core", body)
}

// AutoLogon signs in as the built-in Administrator with admin_password by
// default; any other account needs its own autologon_password.
fn autologon_xml(params: Value, admin_pw: string) -> Result[string, string] {
    if !common::param_bool(params, "autologon", false) { return Ok("") }
    let user = common::param_str(params, "autologon_user", "Administrator")
    if user.trim() == "" { return Err("'autologon_user' must not be empty") }
    let count = common::param_int(params, "autologon_count", 1)
    if count < 1 { return Err("'autologon_count' must be at least 1") }
    let pw = common::param_str(params, "autologon_password", "")
    if pw == "" {
        if user.to_lower() != "administrator" {
            return Err("'autologon' as '" + user + "' requires 'autologon_password'")
        }
        if admin_pw == "" {
            return Err("'autologon' as Administrator requires 'admin_password' or 'autologon_password'")
        }
        pw = admin_pw
    }
    Ok("      <AutoLogon>" + el("Enabled", "true") +
        el("LogonCount", str(count)) +
        el("Username", common::xml_esc(user)) +
        "<Password>" + common::hidden_password(pw, "Password") + "</Password></AutoLogon>\n")
}

fn shell_setup_component(params: Value, arch: string) -> Result[string, string] {
    let pw = common::param_str(params, "admin_password", "")
    let o_oobe = if common::param_bool(params, "skip_oobe_screens", true) { oobe_block(pw != "") } else { "" }
    let o_ua = if pw != "" {
        "      <UserAccounts><AdministratorPassword>" + common::hidden_password(pw, "AdministratorPassword") +
        "</AdministratorPassword></UserAccounts>\n"
    } else { "" }
    let o_al = autologon_xml(params, pw)?
    let cmds = common::param_list(params, "first_logon_commands")
    let o_flc = if cmds.len() > 0 { first_logon_xml(cmds) } else { "" }
    let tz = common::param_str(params, "timezone", "")
    let o_tz = if tz != "" { "      " + el("TimeZone", common::xml_esc(tz)) + "\n" } else { "" }
    let body = o_oobe + o_ua + o_al + o_flc + o_tz
    if body == "" { return Ok("") }
    Ok(component(arch, "Microsoft-Windows-Shell-Setup", body))
}

// In content mode every detectable structured param must be unset — silently
// ignoring one would hide a real authoring mistake (a password the user thinks
// is in the file, but is not). skip_oobe_screens and architecture cannot
// participate: their defaults are merged before the script runs, so "left at
// default" and "explicitly set" are indistinguishable — documented as ignored
// in content mode.
fn reject_structured(params: Value) -> Result[unit, string] {
    let conflicts = common::param_str(params, "admin_password", "") != "" ||
        common::param_bool(params, "autologon", false) ||
        common::param_str(params, "autologon_password", "") != "" ||
        !common::param_list(params, "first_logon_commands").is_empty() ||
        common::param_str(params, "input_locale", "") != "" ||
        common::param_str(params, "system_locale", "") != "" ||
        common::param_str(params, "user_locale", "") != "" ||
        common::param_str(params, "ui_language", "") != "" ||
        common::param_str(params, "timezone", "") != ""
    if conflicts { return Err("'content' is mutually exclusive with the structured unattend params") }
    Ok(())
}

fn desired_xml(params: Value) -> Result[string, string] {
    let raw = common::param_str(params, "content", "")
    if raw != "" {
        reject_structured(params)?
        return Ok(raw)
    }
    let arch = architecture(params)?
    Ok("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
       "<unattend xmlns=\"urn:schemas-microsoft-com:unattend\"" +
       " xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\">\n" +
       "  <settings pass=\"oobeSystem\">\n" +
       intl_component(params, arch) + shell_setup_component(params, arch)? +
       "  </settings>\n" +
       "</unattend>\n")
}

fn target(params: Value) -> Result[string, string] {
    let p = common::param_str(params, "path", "")
    if p.trim() == "" { return Err("missing 'path' parameter") }
    if p.contains("\n") || p.contains("\r") { return Err("'path' must not contain a line break") }
    Ok(p)
}

// The file holds passwords, so only SYSTEM and Administrators may read it on
// Windows (a protected DACL with nothing inherited), and only the owner on
// Linux (mode 0600).
fn acl_env(p: string) -> Value { Value::Map(#{ "env": Value::Map(#{ "CW_PATH": Value::String(p) }) }) }

fn restricted(p: string) -> Result[bool, string] {
    if sys::family() != "windows" {
        let meta = fs::metadata(p)?
        if let Some(m) = meta.get("mode") { if let Some(mode) = m.as_int() { return Ok(mode % 512 == 384) } }
        return Ok(false)
    }
    let script = "$ErrorActionPreference = 'Stop'\n" +
        "$a = Get-Acl -LiteralPath $env:CW_PATH\n" +
        "$ok = @('S-1-5-18', 'S-1-5-32-544')\n" +
        "$bad = @($a.Access | Where-Object {{ $ok -notcontains $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }})\n" +
        "if ($a.AreAccessRulesProtected -and $bad.Count -eq 0) {{ 'yes' }} else {{ 'no' }}\n"
    let out = shell::powershell(script, acl_env(p))?
    if !out.success { return Err("reading the answer file's ACL failed (exit " + str(out.code) + "): " + out.stderr.trim()) }
    Ok(out.stdout.trim() == "yes")
}

fn restrict(p: string) -> Result[unit, string] {
    if sys::family() != "windows" {
        let out = shell::bash("chmod 600 -- \"$CW_PATH\"", acl_env(p))?
        if !out.success { return Err("chmod 600 failed (exit " + str(out.code) + "): " + out.stderr.trim()) }
        return Ok(())
    }
    let script = "$ErrorActionPreference = 'Stop'\n" +
        "$acl = New-Object System.Security.AccessControl.FileSecurity\n" +
        "$acl.SetAccessRuleProtection($true, $false)\n" +
        "foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {{\n" +
        "  $id = New-Object System.Security.Principal.SecurityIdentifier($sid)\n" +
        "  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))\n" +
        "}}\n" +
        "(Get-Item -LiteralPath $env:CW_PATH -Force).SetAccessControl($acl)\n"
    let out = shell::powershell(script, acl_env(p))?
    if !out.success { return Err("restricting the answer file's ACL failed (exit " + str(out.code) + "): " + out.stderr.trim()) }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = target(params)?
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = desired_xml(params)?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    // A file that is not UTF-8 (Windows SIM saves UTF-16) cannot match.
    let have = fs::read(p)
    if let Ok(text) = have {
        if text != want { return Ok(CheckResult::NotConfigured) }
    } else {
        return Ok(CheckResult::NotConfigured)
    }
    if !restricted(p)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = target(params)?
    if !common::want_present(params)? {
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let want = desired_xml(params)?
    log::info("writing answer file " + p)
    fs::mkdir(path::parent(p))?
    // Truncate and lock the file down before the passwords go in.
    fs::write(p, "")?
    restrict(p)?
    fs::write(p, want)?
    Ok(ApplyResult::Success)
}
