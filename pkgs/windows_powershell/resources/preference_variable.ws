use value
use fs
use path
use shell
use sys

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
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

// Every PowerShell invocation carries a timeout. A resource that can hang
// forever is a defect: the timeout kills the child and surfaces an Err, which
// the engine reports as a failed step naming this resource.
fn run_ps(edition: string, script: string) -> Result[CmdOutput, string] {
    let dir = fs::temp_dir()?
    let file = path::join(dir, "config-weave-ps.ps1")
    fs::write(file, "$ErrorActionPreference = 'Stop'\n" + script)?
    let ep = if sys::family() == "windows" { " -ExecutionPolicy Bypass" } else { "" }
    let out = shell::run(dq(ps_exe(edition)) + " -NoProfile -NonInteractive" + ep + " -File " + dq(file), Value::Map(#{ "timeout": Value::Int(300) }))
    fs::delete_dir(dir)?
    out
}

fn profile_dir(params: Value, all_users: bool) -> Result[string, string] {
    let edition = param_str(params, "edition", "auto")
    if all_users {
        let out = run_ps(edition, "Write-Output $PSHOME")?
        if !out.success { return Err("cannot resolve $PSHOME: " + out.stderr.trim()) }
        return Ok(out.stdout.trim())
    }
    let home = param_str(params, "home", "")
    if home != "" {
        if sys::family() == "windows" {
            let folder = if resolved_edition(edition) == "windows_powershell" { "WindowsPowerShell" } else { "PowerShell" }
            return Ok(path::join(path::join(home, "Documents"), folder))
        }
        return Ok(path::join(path::join(home, ".config"), "powershell"))
    }
    let out = run_ps(edition, "Write-Output (Split-Path -Parent $PROFILE.CurrentUserCurrentHost)")?
    if !out.success { return Err("cannot resolve the user profile directory: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn profile_path(params: Value) -> Result[string, string] {
    let explicit = param_str(params, "path", "")
    if explicit != "" { return Ok(explicit) }
    let scope = param_str(params, "scope", "current_user_current_host")
    let valid = ["all_users_all_hosts", "all_users_current_host", "current_user_all_hosts", "current_user_current_host"]
    if !valid.contains(scope) { return Err("invalid 'scope' value '" + scope + "'") }
    let dir = profile_dir(params, scope.starts_with("all_users"))?
    if scope.ends_with("all_hosts") { return Ok(path::join(dir, "profile.ps1")) }
    Ok(path::join(dir, param_str(params, "host", "Microsoft.PowerShell") + "_profile.ps1"))
}

fn begin_marker(name: string) -> string { "# BEGIN config-weave: " + name }
fn end_marker(name: string) -> string { "# END config-weave: " + name }

// Files written on Windows come back with CRLF; the markers are matched on a
// trimmed line, but the body has to be normalised or it would never compare
// equal to the body we intend to write.
fn strip_cr(line: string) -> string {
    if line.ends_with("\r") { return line.slice(0, line.len() - 1) }
    line
}

// extract_block / merge_block are deliberately pure string functions: the
// whole convergence contract of the five block-writing resources lives in
// them, and pure functions can be exercised without a host.

// The body currently between this block's markers, or None when the block is
// not in the text at all.
fn extract_block(text: string, name: string) -> Option[string] {
    let begin = begin_marker(name)
    let end = end_marker(name)
    let body: List[string] = []
    let inside = false
    let found = false
    for raw in text.split("\n") {
        let line = strip_cr(raw)
        if !inside && line.trim() == begin {
            inside = true
            found = true
            continue
        }
        if inside {
            if line.trim() == end { inside = false } else { body.push(line) }
            continue
        }
    }
    if !found { return None }
    Some(body.join("\n"))
}

// Replaces the block in place when it is already there, appends it otherwise,
// and drops it entirely when `body` is None — leaving every other line of the
// profile untouched.
fn merge_block(text: string, name: string, body: Option[string]) -> string {
    let begin = begin_marker(name)
    let end = end_marker(name)
    let rendered = ""
    if let Some(b) = body { rendered = begin + "\n" + b + "\n" + end }
    let kept: List[string] = []
    let inside = false
    let seen = false
    for raw in text.split("\n") {
        let line = strip_cr(raw)
        if !inside && line.trim() == begin {
            inside = true
            seen = true
            if rendered != "" { kept.push(rendered) }
            continue
        }
        if inside {
            if line.trim() == end { inside = false }
            continue
        }
        kept.push(line)
    }
    let head = kept.join("\n").trim_end()
    if seen || rendered == "" {
        if head == "" { return "" }
        return head + "\n"
    }
    if head == "" { return rendered + "\n" }
    head + "\n\n" + rendered + "\n"
}

fn read_block(file: string, name: string) -> Result[Option[string], string] {
    if !fs::is_file(file) { return Ok(None) }
    Ok(extract_block(fs::read(file)?, name))
}

fn write_block(file: string, name: string, body: Option[string]) -> Result[unit, string] {
    let existing = if fs::is_file(file) { fs::read(file)? } else { "" }
    let parent = path::parent(file)
    if parent != "" { fs::mkdir(parent)? }
    fs::write(file, merge_block(existing, name, body))
}


fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// Not a mechanical PascalCase of the symbol: several of these carry a PS
// prefix ($PSModuleAutoLoadingPreference) that the symbol name does not.
fn variable_name(symbol: string) -> Result[string, string] {
    let table = #{
        "confirm_preference": "ConfirmPreference",
        "debug_preference": "DebugPreference",
        "error_action_preference": "ErrorActionPreference",
        "error_view": "ErrorView",
        "information_preference": "InformationPreference",
        "progress_preference": "ProgressPreference",
        "verbose_preference": "VerbosePreference",
        "warning_preference": "WarningPreference",
        "whatif_preference": "WhatIfPreference",
        "module_autoloading_preference": "PSModuleAutoLoadingPreference",
        "maximum_history_count": "MaximumHistoryCount",
        "output_encoding": "OutputEncoding",
        "native_command_argument_passing": "PSNativeCommandArgumentPassing",
        "native_command_use_error_action_preference": "PSNativeCommandUseErrorActionPreference",
        "style": "PSStyle",
        "default_parameter_values": "PSDefaultParameterValues",
        "session_option": "PSSessionOption",
        "email_server": "PSEmailServer",
        "transcript": "Transcript"
    }
    if let Some(name) = table.get(symbol) { return Ok(name) }
    Err("unknown preference variable '" + symbol + "'")
}

fn render_value(params: Value) -> Result[string, string] {
    let raw = param_str(params, "value", "")
    let kind = param_str(params, "value_type", "string")
    if kind == "string" { return Ok(ps_q(raw)) }
    if kind == "raw" { return Ok(raw) }
    if kind == "bool" {
        let normal = raw.trim().to_lower()
        if normal == "true" { return Ok("$true") }
        if normal == "false" { return Ok("$false") }
        return Err("value_type :bool needs true or false, got '" + raw + "'")
    }
    if kind == "int" {
        if raw.trim().parse_int().is_none() { return Err("value_type :int needs a whole number, got '" + raw + "'") }
        return Ok(raw.trim())
    }
    Err("unknown 'value_type' '" + kind + "'")
}

fn block_name(params: Value) -> Result[string, string] {
    let symbol = param_str(params, "name", "")
    if symbol == "" { return Err("missing 'name' parameter") }
    Ok("preference-" + symbol.replace("_", "-"))
}

fn desired_body(params: Value) -> Result[string, string] {
    let symbol = param_str(params, "name", "")
    if symbol == "" { return Err("missing 'name' parameter") }
    Ok("$" + variable_name(symbol)? + " = " + render_value(params)?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    // Resolving the profile path runs the target PowerShell, which may not
    // be installed yet: run 1 checks every step before the install step has
    // applied. That is "not configured", not a failure.
    let file = ""
    if let Ok(resolved) = profile_path(params) { file = resolved } else {
        if want_present(params)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let current = read_block(file, block_name(params)?)?
    if !want_present(params)? {
        if current.is_none() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if let Some(body) = current {
        if body == desired_body(params)? { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let file = profile_path(params)?
    let name = block_name(params)?
    if !want_present(params)? {
        write_block(file, name, None)?
        return Ok(ApplyResult::Success)
    }
    write_block(file, name, Some(desired_body(params)?))?
    Ok(ApplyResult::Success)
}
