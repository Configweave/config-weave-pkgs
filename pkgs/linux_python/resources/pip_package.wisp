use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn pip_bin(params: Value) -> string {
    let exe = param_str(params, "executable", "pip3")
    let venv = param_str(params, "virtualenv", "")
    if venv != "" { return venv + "/bin/" + exe }
    exe
}

// Installed version, or "" when the package is not installed.
fn pip_version(pip: string, name: string) -> Result[string, string] {
    let out = shell::bash(q(pip) + " show " + q(name) + " 2>/dev/null", Value::Null)?
    if !out.success { return Ok("") }
    for line in out.stdout.split("\n") {
        if line.starts_with("Version: ") { return Ok(line.slice(9, line.len())) }
    }
    Ok("")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    if name == "" { return Err("missing 'name' parameter") }
    let iv = pip_version(pip_bin(params), name)?
    if version == "" {
        if iv != "" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if iv == version { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    if name == "" { return Err("missing 'name' parameter") }
    let spec = if version != "" { name + "==" + version } else { name }
    let out = shell::bash(q(pip_bin(params)) + " install " + q(spec), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
