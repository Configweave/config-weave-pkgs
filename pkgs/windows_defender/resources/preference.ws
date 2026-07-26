use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

// The preference name is spliced into the script as a property/parameter
// name, so it must look like one — anything else is rejected rather than
// quoted.
fn pref_name(params: Value) -> Result[string, string] {
    let name = param_str(params, "name", "").trim()
    if name == "" { return Err("missing 'name' parameter") }
    for bad in [" ", "\t", "\n", "'", "\"", "`", ";", "$", "-", "(", ")", "{{", "}}", "[", "]", "|", "&", ".", ","] {
        if name.contains(bad) {
            return Err("invalid 'name' value '" + name + "' (expected a Set-MpPreference parameter name such as ScanScheduleDay)")
        }
    }
    Ok(name)
}

// $true/$false and bare numbers pass through unquoted; everything else is a
// single-quoted string.
fn value_arg(value: string) -> string {
    if value == "$true" || value == "$false" { return value }
    if value.parse_int().is_some() { return value }
    if value.parse_float().is_some() { return value }
    ps_q(value)
}

// Get-MpPreference stringifies booleans as True/False, so the declared
// $true/$false spelling is normalised before comparing.
fn want_str(value: string) -> string {
    if value == "$true" { return "True" }
    if value == "$false" { return "False" }
    value
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = pref_name(params)?
    let value = param_str(params, "value", "")
    if value == "" { return Err("missing 'value' parameter") }
    let cur = ps_out("[string](Get-MpPreference)." + name)?
    if cur == want_str(value) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = pref_name(params)?
    let value = param_str(params, "value", "")
    if value == "" { return Err("missing 'value' parameter") }
    ps_run("Set-MpPreference -" + name + " " + value_arg(value))?
    Ok(ApplyResult::Success)
}
