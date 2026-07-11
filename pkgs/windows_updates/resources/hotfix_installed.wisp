use value
use fs
use path
use http
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn present(kb: string) -> Result[bool, string] {
    let script = "if (Get-HotFix -Id " + ps_q(kb) + " -ErrorAction SilentlyContinue) {{ 'YES' }} else {{ 'NO' }}"
    Ok(shell::powershell(script, Value::Null)?.stdout.trim() == "YES")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let kb = param_str(params, "kb", "")
    if kb == "" { return Err("missing 'kb' parameter (e.g. KB5031234)") }
    if present(kb)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let kb = param_str(params, "kb", "")
    let src = param_str(params, "path", "")
    if kb == "" { return Err("missing 'kb' parameter") }
    if src == "" { return Err("hotfix " + kb + " is not installed and no 'path' to an .msu was given") }
    let local = if src.starts_with("http") {
        let f = path::join(fs::temp_dir()?, kb + ".msu")
        http::download(src, f, Value::Null)?
        f
    } else {
        src
    }
    let argline = "\"" + local + "\" /quiet /norestart"
    let script = "$c = (Start-Process -FilePath 'wusa.exe' -ArgumentList " + ps_q(argline) + " -Wait -PassThru).ExitCode; exit $c"
    let out = shell::powershell(script, Value::Null)?
    // 3010 = reboot required; 2359302 = already installed.
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if out.code == 2359302 { return Ok(ApplyResult::Success) }
    if !out.success { return Err("wusa exited " + str(out.code)) }
    Ok(ApplyResult::Success)
}
