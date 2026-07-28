use value
use fs
use path
use shell
use sys
use json

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

fn unavailable() -> Value {
    let empty: Map[string, Value] = #{}
    Value::Map(#{
        "available": Value::Bool(false),
        "module_version": Value::String(""),
        "edit_mode": Value::String(""),
        "prediction_source": Value::String(""),
        "prediction_view_style": Value::String(""),
        "history_save_style": Value::String(""),
        "history_save_path": Value::String(""),
        "maximum_history_count": Value::Int(-1),
        "options": Value::Map(empty)
    })
}

fn scalar(options: Value, key: string) -> string {
    if let Some(v) = options.get(key) {
        if let Some(s) = v.as_string() { return s }
        if let Some(n) = v.as_int() { return str(n) }
        if let Some(b) = v.as_bool() { return str(b) }
    }
    ""
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = param_str(params, "edition", "auto")
    // Only the scalar properties: the colour properties are ConsoleColor
    // objects that do not survive a JSON round trip usefully.
    let script = "Import-Module PSReadLine -ErrorAction Stop\n$o = Get-PSReadLineOption\n$m = (Get-Module PSReadLine).Version.ToString()\n$out = [ordered]@{{ module_version = $m }}\nforeach ($p in $o.PSObject.Properties) {{ if ($p.Value -is [string] -or $p.Value -is [int] -or $p.Value -is [bool] -or $p.Value -is [enum]) {{ $out[$p.Name] = [string]$p.Value }} }}\n$out | ConvertTo-Json -Compress -Depth 3"
    let out = run_ps(edition, script)
    if let Ok(result) = out {
        if result.success {
            let text = result.stdout.trim()
            if text != "" {
                let options = json::parse(text)?
                return Ok(Value::Map(#{
                    "available": Value::Bool(true),
                    "module_version": Value::String(scalar(options, "module_version")),
                    "edit_mode": Value::String(scalar(options, "EditMode")),
                    "prediction_source": Value::String(scalar(options, "PredictionSource")),
                    "prediction_view_style": Value::String(scalar(options, "PredictionViewStyle")),
                    "history_save_style": Value::String(scalar(options, "HistorySaveStyle")),
                    "history_save_path": Value::String(scalar(options, "HistorySavePath")),
                    "maximum_history_count": Value::Int(scalar(options, "MaximumHistoryCount").parse_int().unwrap_or(-1)),
                    "options": options
                }))
            }
        }
    }
    Ok(unavailable())
}
