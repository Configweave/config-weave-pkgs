use value
use common

// `name` may name its bucket ("extras/vscode"); scoop installs the app
// under its bare name, which is what the probe and uninstall use.
fn app_name(name: string) -> string {
    let parts = name.split("/")
    parts.get(parts.len() - 1).unwrap_or("")
}

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let parts = name.split("/")
    if parts.len() > 2 { return Err("'name' must be app or bucket/app, got '" + name + "'") }
    for part in parts { common::validate_name("name", part)? }
    common::want_present(params)?
    Ok(name)
}

// Installed when the app's `current` junction exists under the scoop root
// (per-user: SCOOP wins, else ~\scoop). The app name travels in the
// environment, never into the script text.
fn installed(app: string) -> Result[bool, string] {
    let script = common::scoop_root_ps() +
        "if (Test-Path -LiteralPath (Join-Path $scoopRoot ('apps\\' + $env:CW_APP + '\\current'))) {{ 'YES' }} else {{ 'NO' }}\n"
    let out = common::query(script, #{ "CW_APP": Value::String(app) })?
    if !out.success { return Err(common::failure("probing scoop app " + app, out)) }
    Ok(out.stdout.trim() == "YES")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    if installed(app_name(name))? == common::want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let verb = if present { "install" } else { "uninstall" }
    let script = common::scoop_ps() + "& $scoop " + verb + " $env:CW_NAME\nexit $LASTEXITCODE\n"
    let out = common::action(script, #{ "CW_NAME": Value::String(if present { name } else { app_name(name) }) })?
    if !out.success { return Err(common::failure("scoop " + verb + " " + name, out)) }
    Ok(ApplyResult::Success)
}
