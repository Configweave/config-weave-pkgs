use value
use common
use profiles

// A chord such as "Ctrl+d,Ctrl+c" has to become a marker-safe block name.
// Case is kept: PSReadLine binds Ctrl+d and Ctrl+D to different keys.
fn slug(s: string) -> string {
    let out = s
    for bad in [":", "+", ",", "*", " ", "\\", "/", "$", "'", "\"", "#"] {
        out = out.replace(bad, "-")
    }
    out
}

fn chord(params: Value) -> Result[string, string] {
    let c = common::param_str(params, "chord", "")
    common::require("chord", c)?
    common::single_line("chord", c)?
    Ok(c)
}

fn block_name(params: Value) -> Result[string, string] {
    Ok("psreadline-key-" + slug(chord(params)?))
}

// Earlier releases lowercased the chord in the block name. A block under
// that name that binds this exact chord is migrated to the new name; one
// that binds a different-case chord belongs to another binding and is left.
fn legacy_block(params: Value) -> Result[Option[string], string] {
    let c = chord(params)?
    let legacy = "psreadline-key-" + slug(c).to_lower()
    if legacy == block_name(params)? { return Ok(None) }
    if let Some(existing) = profiles::current_block(params, legacy)? {
        if existing.contains("-Chord " + common::ps_q(c) + " ") { return Ok(Some(legacy)) }
    }
    Ok(None)
}

fn desired_body(params: Value) -> Result[string, string] {
    let key_chord = chord(params)?
    let function = common::param_str(params, "function", "")
    let script_block = common::param_str(params, "script_block", "")
    if function == "" && script_block == "" {
        return Err("one of 'function' or 'script_block' is required")
    }
    if function != "" && script_block != "" {
        return Err("'function' and 'script_block' are mutually exclusive")
    }
    let action = if function != "" {
        " -Function " + common::ps_q(function)
    } else {
        " -ScriptBlock {{ " + script_block + " }}"
    }
    let described = common::param_str(params, "description_text", "")
    let description = if described == "" { "" } else { " -Description " + common::ps_q(described) }
    let mode = common::param_str(params, "view_mode", "unmanaged")
    let vi_mode = if mode == "unmanaged" { "" } else { " -ViMode " + common::pascal(mode) }
    let call = "    Set-PSReadLineKeyHandler -Chord " + common::ps_q(key_chord) + action + description + vi_mode
    Ok("if ($null -ne (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) {{\n" + call + "\n}}")
}

fn body(params: Value) -> Result[Option[string], string] {
    if common::want_present(params)? { return Ok(Some(desired_body(params)?)) }
    Ok(None)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if legacy_block(params)?.is_some() { return Ok(CheckResult::NotConfigured) }
    profiles::check_block(params, block_name(params)?, body(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if let Some(legacy) = legacy_block(params)? { profiles::apply_block(params, legacy, None)? }
    profiles::apply_block(params, block_name(params)?, body(params)?)
}
