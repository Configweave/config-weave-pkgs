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

fn installed(pip: string, name: string) -> Result[bool, string] {
    Ok(shell::bash(q(pip) + " show " + q(name) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if installed(pip_bin(params), name)? { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let out = shell::bash(q(pip_bin(params)) + " uninstall -y " + q(name), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
