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


fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

// WCL symbols are lower_snake_case; the PSReadLine values they name are
// PascalCase — :history_and_plugin is HistoryAndPlugin.
fn pascal(symbol: string) -> string {
    let out = ""
    for word in symbol.split("_") {
        if word != "" { out = out + word.slice(0, 1).to_upper() + word.slice(1, word.len()) }
    }
    out
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn sym_line(params: Value, key: string, flag: string) -> string {
    let v = param_str(params, key, "unmanaged")
    if v == "unmanaged" { return "" }
    "Set-PSReadLineOption -" + flag + " " + pascal(v)
}

fn bool_line(params: Value, key: string, flag: string) -> Result[string, string] {
    let v = param_str(params, key, "unmanaged")
    if v == "unmanaged" { return Ok("") }
    if v == "enabled" { return Ok("Set-PSReadLineOption -" + flag + ":$true") }
    if v == "disabled" { return Ok("Set-PSReadLineOption -" + flag + ":$false") }
    Err("invalid '" + key + "' value '" + v + "' (expected :enabled, :disabled or :unmanaged)")
}

fn int_line(params: Value, key: string, flag: string) -> string {
    let n = param_int(params, key, -1)
    if n < 0 { return "" }
    "Set-PSReadLineOption -" + flag + " " + str(n)
}

fn str_line(params: Value, key: string, flag: string) -> string {
    let s = param_str(params, key, "")
    if s == "" { return "" }
    "Set-PSReadLineOption -" + flag + " " + ps_q(s)
}

// Map keys come out sorted, so the generated hashtable is byte-stable across
// runs — which is what lets check compare it to what is already on disk.
fn colors_line(params: Value) -> string {
    if let Some(v) = params.get("colors") {
        if let Some(m) = v.as_map() {
            let names = m.keys()
            if names.is_empty() { return "" }
            let pairs: List[string] = []
            for name in names {
                pairs.push(ps_q(name) + " = " + ps_q(m[name].as_string().unwrap_or("")))
            }
            return "Set-PSReadLineOption -Colors @{{ " + pairs.join("; ") + " }}"
        }
    }
    ""
}

fn block_name(params: Value) -> string {
    let name = param_str(params, "block_name", "psreadline")
    if name == "" { return "psreadline" }
    name
}

// The guard matters: these options only exist in a host that loaded
// PSReadLine, and an unguarded call would break every non-interactive session
// that dot-sources the profile.
fn desired_body(params: Value) -> Result[string, string] {
    let candidates = [
        sym_line(params, "edit_mode", "EditMode"),
        sym_line(params, "prediction_source", "PredictionSource"),
        sym_line(params, "prediction_view_style", "PredictionViewStyle"),
        sym_line(params, "history_save_style", "HistorySaveStyle"),
        sym_line(params, "bell_style", "BellStyle"),
        sym_line(params, "vi_mode_indicator", "ViModeIndicator"),
        str_line(params, "history_save_path", "HistorySavePath"),
        str_line(params, "continuation_prompt", "ContinuationPrompt"),
        str_line(params, "word_delimiters", "WordDelimiters"),
        str_line(params, "prompt_text", "PromptText"),
        int_line(params, "maximum_history_count", "MaximumHistoryCount"),
        int_line(params, "maximum_kill_ring_count", "MaximumKillRingCount"),
        int_line(params, "ding_tone", "DingTone"),
        int_line(params, "ding_duration", "DingDuration"),
        int_line(params, "completion_query_items", "CompletionQueryItems"),
        int_line(params, "extra_prompt_line_count", "ExtraPromptLineCount"),
        int_line(params, "ansi_escape_timeout", "AnsiEscapeTimeout"),
        bool_line(params, "history_no_duplicates", "HistoryNoDuplicates")?,
        bool_line(params, "history_search_cursor_moves_to_end", "HistorySearchCursorMovesToEnd")?,
        bool_line(params, "history_search_case_sensitive", "HistorySearchCaseSensitive")?,
        bool_line(params, "show_tooltips", "ShowToolTips")?,
        bool_line(params, "terminate_orphaned_console_apps", "TerminateOrphanedConsoleApps")?,
        colors_line(params)
    ]
    let lines: List[string] = []
    for candidate in candidates {
        if candidate != "" { lines.push("    " + candidate) }
    }
    if lines.is_empty() { return Err("no PSReadLine option was set — every option is :unmanaged, -1 or empty") }
    Ok("if ($null -ne (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {{\n" + lines.join("\n") + "\n}}")
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
    let current = read_block(file, block_name(params))?
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
    if !want_present(params)? {
        write_block(file, block_name(params), None)?
        return Ok(ApplyResult::Success)
    }
    write_block(file, block_name(params), Some(desired_body(params)?))?
    Ok(ApplyResult::Success)
}
