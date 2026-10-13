use value
use path
use shell
use sys
use env
use common

fn string_list(values: List[string]) -> Value {
    let items: List[Value] = []
    for v in values { items.push(Value::String(v)) }
    Value::List(items)
}

// "" rather than an error when the binary is missing: a gatherer failure
// aborts the entire run before any step, so absence must be a fact.
fn version_of(exe: string) -> string {
    if !common::on_path(exe) { return "" }
    let out = shell::run(common::dq(exe) + " -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Map(#{ "timeout": Value::Int(120) }))
    if let Ok(result) = out {
        if result.success { return result.stdout.trim() }
    }
    ""
}

fn user_dir(params: Value, edition: string) -> string {
    let home = common::param_str(params, "home", "")
    if home == "" { return "" }
    if sys::family() == "windows" {
        let folder = if common::resolved_edition(edition) == "windows_powershell" { "WindowsPowerShell" } else { "PowerShell" }
        return path::join(path::join(home, "Documents"), folder)
    }
    path::join(path::join(home, ".config"), "powershell")
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = common::param_str(params, "edition", "auto")
    let resolved = common::resolved_edition(edition)
    let pwsh_version = version_of(common::pwsh_binary(false))
    let winps_version = if sys::family() == "windows" { version_of("powershell") } else { "" }

    let empty: List[string] = []
    let ps_home = ""
    let module_paths = empty
    let profiles: Map[string, Value] = #{}

    // One round trip for everything path-shaped, since each one costs a
    // process start.
    let script = "$p = $PROFILE\nWrite-Output $PSHOME\nWrite-Output $p.AllUsersAllHosts\nWrite-Output $p.AllUsersCurrentHost\nWrite-Output $p.CurrentUserAllHosts\nWrite-Output $p.CurrentUserCurrentHost\nWrite-Output $env:PSModulePath"
    // Not installed is the empty shape; installed but unable to answer is an
    // error.
    if let Some(text) = common::query(edition, script)? {
        let cleaned: List[string] = []
        for line in text.split("\n") { cleaned.push(line.trim()) }
        if cleaned.len() >= 6 {
            ps_home = cleaned[0]
            profiles["all_users_all_hosts"] = Value::String(cleaned[1])
            profiles["all_users_current_host"] = Value::String(cleaned[2])
            profiles["current_user_all_hosts"] = Value::String(cleaned[3])
            profiles["current_user_current_host"] = Value::String(cleaned[4])
            let separator = if sys::family() == "windows" { ";" } else { ":" }
            let entries: List[string] = []
            for part in cleaned[5].split(separator) {
                let trimmed = part.trim()
                if trimmed != "" { entries.push(trimmed) }
            }
            module_paths = entries
        }
    }

    // An explicit `home` overrides what the probe reported, because the probe
    // ran with whatever HOME the agent had.
    let overridden = user_dir(params, edition)
    if overridden != "" {
        let host_profile = "Microsoft.PowerShell_profile.ps1"
        profiles["current_user_all_hosts"] = Value::String(path::join(overridden, "profile.ps1"))
        profiles["current_user_current_host"] = Value::String(path::join(overridden, host_profile))
    }

    let configs: Map[string, Value] = #{}
    if ps_home != "" { configs["all_users"] = Value::String(path::join(ps_home, "powershell.config.json")) }
    let user_config_dir = if overridden != "" { overridden } else { "" }
    if user_config_dir == "" {
        if let Some(p) = profiles.get("current_user_current_host") {
            user_config_dir = path::parent(p.as_string().unwrap_or(""))
        }
    }
    if user_config_dir != "" { configs["current_user"] = Value::String(path::join(user_config_dir, "powershell.config.json")) }

    let reported = if resolved == "windows_powershell" { winps_version } else { pwsh_version }
    let versions: List[string] = []
    if pwsh_version != "" { versions.push(pwsh_version) }
    if winps_version != "" { versions.push(winps_version) }

    Ok(Value::Map(#{
        "family": Value::String(sys::family()),
        "pwsh_installed": Value::Bool(pwsh_version != ""),
        "pwsh_version": Value::String(pwsh_version),
        "pwsh_home": Value::String(if resolved == "windows_powershell" { "" } else { ps_home }),
        "windows_powershell_installed": Value::Bool(winps_version != ""),
        "windows_powershell_version": Value::String(winps_version),
        "edition": Value::String(resolved),
        "version": Value::String(reported),
        "ps_home": Value::String(ps_home),
        "module_paths": string_list(module_paths),
        "profile_paths": Value::Map(profiles),
        "config_paths": Value::Map(configs),
        "elevated": Value::Bool(env::is_elevated()),
        "versions": string_list(versions)
    }))
}
