use value
use fs
use path
use shell
use sys
use json
use env

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
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

fn resolved_edition(edition: string) -> string {
    if edition != "auto" { return edition }
    if sys::family() == "windows" { "windows_powershell" } else { "pwsh" }
}

// The MSI's PATH change is invisible to an already-running process, so a
// PowerShell installed earlier in this same run cannot be found by name.
// The well-known install roots are probed before falling back to PATH.
fn pwsh_binary(preview: bool) -> string {
    if sys::family() != "windows" {
        if preview { return "pwsh-preview" }
        return "pwsh"
    }
    let pattern = if preview { "C:\\Program Files\\PowerShell\\*-preview\\pwsh.exe" } else { "C:\\Program Files\\PowerShell\\*\\pwsh.exe" }
    if let Ok(found) = fs::glob(pattern) {
        let best = ""
        for candidate in found {
            if !preview && candidate.contains("-preview") { continue }
            best = candidate
        }
        if best != "" { return best }
    }
    "pwsh"
}

fn ps_exe(edition: string) -> string {
    let resolved = resolved_edition(edition)
    if resolved == "windows_powershell" { return "powershell" }
    pwsh_binary(resolved == "pwsh_preview")
}

fn dq(s: string) -> string { "\"" + s + "\"" }
fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// Every PowerShell invocation carries a timeout. A resource that can hang
// forever is a defect: the timeout kills the child and surfaces an Err, which
// the engine reports as a failed step naming this resource.
fn ps_argv(edition: string, file: string) -> string {
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file)
}

fn run_ps(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let out = shell::run(ps_argv(edition, file), Value::Map(#{ "timeout": Value::Int(300) }))
    fs::delete_dir(dir)?
    out
}

fn run_ps_streaming(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let out = shell::run_streaming(ps_argv(edition, file), Value::Map(#{ "timeout": Value::Int(2400) }))
    fs::delete_dir(dir)?
    out
}

fn ps_json(edition: string, script: string) -> Result[Value, string] {
    let out = run_ps(edition, script)?
    if !out.success { return Err(out.stderr.trim() + " " + out.stdout.trim()) }
    let text = out.stdout.trim()
    if text == "" { return Ok(Value::Null) }
    json::parse(text)
}

fn pascal(symbol: string) -> string {
    let out = ""
    for word in symbol.split("_") {
        if word != "" { out = out + word.slice(0, 1).to_upper() + word.slice(1, word.len()) }
    }
    out
}


fn string_list(values: List[string]) -> Value {
    let items: List[Value] = []
    for v in values { items.push(Value::String(v)) }
    Value::List(items)
}

// "" rather than an error when the binary is missing: a gatherer failure
// aborts the entire run before any step, so absence must be a fact.
fn version_of(exe: string) -> string {
    let out = shell::run(dq(exe) + " -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)
    if let Ok(result) = out {
        if result.success { return result.stdout.trim() }
    }
    ""
}

fn user_dir(params: Value, edition: string) -> string {
    let home = param_str(params, "home", "")
    if home == "" { return "" }
    if sys::family() == "windows" {
        let folder = if resolved_edition(edition) == "windows_powershell" { "WindowsPowerShell" } else { "PowerShell" }
        return path::join(path::join(home, "Documents"), folder)
    }
    path::join(path::join(home, ".config"), "powershell")
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = param_str(params, "edition", "auto")
    let resolved = resolved_edition(edition)
    let pwsh_version = version_of("pwsh")
    let winps_version = if sys::family() == "windows" { version_of("powershell") } else { "" }

    let empty: List[string] = []
    let ps_home = ""
    let module_paths = empty
    let profiles: Map[string, Value] = #{}

    // One round trip for everything path-shaped, since each one costs a
    // process start.
    let script = "$p = $PROFILE\nWrite-Output $PSHOME\nWrite-Output $p.AllUsersAllHosts\nWrite-Output $p.AllUsersCurrentHost\nWrite-Output $p.CurrentUserAllHosts\nWrite-Output $p.CurrentUserCurrentHost\nWrite-Output $env:PSModulePath"
    let probe = run_ps(edition, script)
    if let Ok(result) = probe {
        if result.success {
            let lines = result.stdout.split("\n")
            let cleaned: List[string] = []
            for line in lines { cleaned.push(line.trim()) }
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
