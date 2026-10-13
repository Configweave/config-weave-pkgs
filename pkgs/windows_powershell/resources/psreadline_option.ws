use value
use common
use profiles

fn sym_line(params: Value, key: string, flag: string) -> string {
    let v = common::param_str(params, key, "unmanaged")
    if v == "unmanaged" { return "" }
    "Set-PSReadLineOption -" + flag + " " + common::pascal(v)
}

fn bool_line(params: Value, key: string, flag: string) -> Result[string, string] {
    let v = common::param_str(params, key, "unmanaged")
    if v == "unmanaged" { return Ok("") }
    if v == "enabled" { return Ok("Set-PSReadLineOption -" + flag + ":$true") }
    if v == "disabled" { return Ok("Set-PSReadLineOption -" + flag + ":$false") }
    Err("invalid '" + key + "' value '" + v + "' (expected :enabled, :disabled or :unmanaged)")
}

fn int_line(params: Value, key: string, flag: string) -> string {
    let n = common::param_int(params, key, -1)
    if n < 0 { return "" }
    "Set-PSReadLineOption -" + flag + " " + str(n)
}

fn str_line(params: Value, key: string, flag: string) -> string {
    let s = common::param_str(params, key, "")
    if s == "" { return "" }
    "Set-PSReadLineOption -" + flag + " " + common::ps_q(s)
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
                pairs.push(common::ps_q(name) + " = " + common::ps_q(m[name].as_string().unwrap_or("")))
            }
            return "Set-PSReadLineOption -Colors @{{ " + pairs.join("; ") + " }}"
        }
    }
    ""
}

fn block_name(params: Value) -> string {
    let name = common::param_str(params, "block_name", "psreadline")
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

fn body(params: Value) -> Result[Option[string], string] {
    if common::want_present(params)? { return Ok(Some(desired_body(params)?)) }
    Ok(None)
}

fn check(params: Value) -> Result[CheckResult, string] {
    profiles::check_block(params, block_name(params), body(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    profiles::apply_block(params, block_name(params), body(params)?)
}
