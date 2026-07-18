use value
use fs
use path
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
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

// & must go first or the entity ampersands get double-escaped.
fn xml_esc(s: string) -> string {
    s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")
}

fn el(name: string, body: string) -> string { "<" + name + ">" + body + "</" + name + ">" }

fn component(name: string, body: string) -> string {
    "    <component name=\"" + name + "\" processorArchitecture=\"amd64\"" +
    " publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">\n" +
    body + "    </component>\n"
}

fn oobe_block() -> string {
    "      <OOBE>\n" +
    "        " + el("HideEULAPage", "true") + "\n" +
    "        " + el("HideLocalAccountScreen", "true") + "\n" +
    "        " + el("HideOEMRegistrationScreen", "true") + "\n" +
    "        " + el("HideOnlineAccountScreens", "true") + "\n" +
    "        " + el("HideWirelessSetupInOOBE", "true") + "\n" +
    "        " + el("ProtectYourPC", "3") + "\n" +
    "      </OOBE>\n"
}

fn pw_value(pw: string) -> string {
    el("Value", xml_esc(pw)) + el("PlainText", "true")
}

fn sync_command(order: int, cmd: string) -> string {
    "        <SynchronousCommand wcm:action=\"add\">\n" +
    "          " + el("Order", str(order)) + "\n" +
    "          " + el("CommandLine", xml_esc(cmd)) + "\n" +
    "        </SynchronousCommand>\n"
}

fn first_logon_xml(cmds: List[string]) -> string {
    let body = ""
    for i in 0..cmds.len() { body = body + sync_command(i + 1, cmds[i]) }
    "      <FirstLogonCommands>\n" + body + "      </FirstLogonCommands>\n"
}

fn intl_component(params: Value) -> string {
    let il = param_str(params, "input_locale", "")
    let sl = param_str(params, "system_locale", "")
    let ul = param_str(params, "ui_language", "")
    let us = param_str(params, "user_locale", "")
    let o_il = if il != "" { "      " + el("InputLocale", xml_esc(il)) + "\n" } else { "" }
    let o_sl = if sl != "" { "      " + el("SystemLocale", xml_esc(sl)) + "\n" } else { "" }
    let o_ul = if ul != "" { "      " + el("UILanguage", xml_esc(ul)) + "\n" } else { "" }
    let o_us = if us != "" { "      " + el("UserLocale", xml_esc(us)) + "\n" } else { "" }
    let body = o_il + o_sl + o_ul + o_us
    if body == "" { return "" }
    component("Microsoft-Windows-International-Core", body)
}

fn shell_setup_component(params: Value) -> Result[string, string] {
    let o_oobe = if param_bool(params, "skip_oobe_screens", true) { oobe_block() } else { "" }
    let pw = param_str(params, "admin_password", "")
    let o_ua = if pw != "" {
        "      <UserAccounts><AdministratorPassword>" + pw_value(pw) + "</AdministratorPassword></UserAccounts>\n"
    } else { "" }
    let o_al = if param_bool(params, "autologon", false) {
        if pw == "" { return Err("'autologon' requires 'admin_password' (it is the logon password)") }
        "      <AutoLogon>" + el("Enabled", "true") +
        el("LogonCount", str(param_int(params, "autologon_count", 1))) +
        el("Username", xml_esc(param_str(params, "autologon_user", "Administrator"))) +
        "<Password>" + pw_value(pw) + "</Password></AutoLogon>\n"
    } else { "" }
    let cmds = param_list(params, "first_logon_commands")
    let o_flc = if cmds.len() > 0 { first_logon_xml(cmds) } else { "" }
    let tz = param_str(params, "timezone", "")
    let o_tz = if tz != "" { "      " + el("TimeZone", xml_esc(tz)) + "\n" } else { "" }
    let body = o_oobe + o_ua + o_al + o_flc + o_tz
    if body == "" { return Ok("") }
    Ok(component("Microsoft-Windows-Shell-Setup", body))
}

// In content mode every detectable structured param must be unset — silently
// ignoring one would hide a real authoring mistake (a password the user thinks
// is in the file, but is not). skip_oobe_screens cannot participate: its
// default is true and the engine merges defaults before the script runs, so
// "left at default" and "explicitly set" are indistinguishable — documented as
// ignored in content mode.
fn reject_structured(params: Value) -> Result[unit, string] {
    let conflicts = param_str(params, "admin_password", "") != "" ||
        param_bool(params, "autologon", false) ||
        !param_list(params, "first_logon_commands").is_empty() ||
        param_str(params, "input_locale", "") != "" ||
        param_str(params, "system_locale", "") != "" ||
        param_str(params, "user_locale", "") != "" ||
        param_str(params, "ui_language", "") != "" ||
        param_str(params, "timezone", "") != ""
    if conflicts { return Err("'content' is mutually exclusive with the structured unattend params") }
    Ok(())
}

fn desired_xml(params: Value) -> Result[string, string] {
    let raw = param_str(params, "content", "")
    if raw != "" {
        reject_structured(params)?
        return Ok(raw)
    }
    Ok("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
       "<unattend xmlns=\"urn:schemas-microsoft-com:unattend\"" +
       " xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\">\n" +
       "  <settings pass=\"oobeSystem\">\n" +
       intl_component(params) + shell_setup_component(params)? +
       "  </settings>\n" +
       "</unattend>\n")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let want = desired_xml(params)?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if fs::read(p)? != want { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let want = desired_xml(params)?
    log::info("writing answer file " + p)
    fs::mkdir(path::parent(p))?
    fs::write(p, want)?
    Ok(ApplyResult::Success)
}
