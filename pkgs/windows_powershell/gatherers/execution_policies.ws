use value
use shell
use sys
use common

// WCL symbols are lower_snake_case; PowerShell reports PascalCase.
fn to_symbol(policy: string) -> string {
    let p = policy.trim().to_lower()
    if p == "restricted" { return "restricted" }
    if p == "allsigned" { return "all_signed" }
    if p == "remotesigned" { return "remote_signed" }
    if p == "unrestricted" { return "unrestricted" }
    if p == "bypass" { return "bypass" }
    if p == "undefined" { return "undefined" }
    "unknown"
}

// MachinePolicy -> machine_policy: the keys the returns doc names.
fn scope_key(scope: string) -> string {
    if scope == "machinepolicy" { return "machine_policy" }
    if scope == "userpolicy" { return "user_policy" }
    if scope == "currentuser" { return "current_user" }
    if scope == "localmachine" { return "local_machine" }
    scope
}

fn unknown_result() -> Value {
    let scopes: Map[string, Value] = #{}
    Value::Map(#{
        "supported": Value::Bool(false),
        "effective": Value::String("unknown"),
        "policies": Value::Map(scopes)
    })
}

fn gather(params: Value) -> Result[Value, string] {
    let edition = common::param_str(params, "edition", "auto")
    // Execution policy is inert off Windows — every scope reports
    // Unrestricted and nothing enforces it.
    let supported = sys::family() == "windows"
    if !common::ps_installed(edition) { return Ok(unknown_result()) }
    // -Command rather than the -File + -ExecutionPolicy Bypass every other
    // query uses: that switch sets the Process scope, which would then read
    // bypass and make the effective policy bypass too. -Command runs under
    // any policy, so nothing has to be bypassed.
    let script = "[string](Get-ExecutionPolicy); Get-ExecutionPolicy -List | ForEach-Object {{ [string]$_.Scope + '=' + [string]$_.ExecutionPolicy }}"
    let out = shell::run(common::dq(common::ps_exe(edition)) + " -NoProfile -NonInteractive -Command " + common::dq(script), Value::Map(#{ "timeout": Value::Int(300) }))?
    if !out.success { return Err(common::failure("Get-ExecutionPolicy", out)) }
    let effective = "unknown"
    let scopes: Map[string, Value] = #{}
    let first = true
    for line in common::lines_of(out.stdout) {
        if first {
            effective = to_symbol(line)
            first = false
            continue
        }
        if let Some(i) = line.find("=") {
            let scope = line.slice(0, i).trim().to_lower()
            let policy = line.slice(i + 1, line.len()).trim()
            scopes[scope_key(scope)] = Value::String(to_symbol(policy))
        }
    }
    Ok(Value::Map(#{
        "supported": Value::Bool(supported),
        "effective": Value::String(effective),
        "policies": Value::Map(scopes)
    }))
}
