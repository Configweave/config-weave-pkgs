use value
use json
use fs
use shell
use log

// ---------------------------------------------------------------------------
// Shared git-config helpers — byte-identical in every script in this package.
//
// wscript has no script-to-script imports yet (config-weave compiles `lib/`
// but cannot resolve it), so this block is duplicated rather than shared.
// Keep the copies identical; moving to lib/ is then a mechanical delete.
//
// Everything goes through the `git config` binary rather than editing the
// INI file directly. git owns the quoting rules (values containing #, ;, "
// or trailing whitespace), multi-valued keys, and the platform-correct
// location of the system config — none of which a hand-rolled writer got
// right. The cost is that the target must have git installed.
// ---------------------------------------------------------------------------

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// --global / --system. Both restrict reads as well as writes, so a probe
// never sees a value inherited from another scope.
fn scope_flag(params: Value) -> Result[string, string] {
    let s = param_str(params, "scope", "global")
    if s == "global" { return Ok("--global") }
    if s == "system" { return Ok("--system") }
    Err("invalid 'scope' value '" + s + "' (expected :global or :system)")
}

// `home` pins --global at an explicit file through GIT_CONFIG_GLOBAL (git
// >= 2.30) instead of mutating HOME: no shell needed, and it works
// unchanged on Windows, where the global config is %USERPROFILE%\.gitconfig.
fn git_opts(params: Value) -> Value {
    let h = param_str(params, "home", "")
    if h == "" { return Value::Null }
    Value::Map(#{ "env": Value::Map(#{ "GIT_CONFIG_GLOBAL": Value::String(h + "/.gitconfig") }) })
}

fn git(params: Value, args: string) -> Result[CmdOutput, string] {
    shell::run("git config " + scope_flag(params)? + " " + args, git_opts(params))
}

// exit 0 = a value, 1 = the key is unset, anything else is a real failure.
fn cfg_get(params: Value, key: string) -> Result[Option[string], string] {
    let out = git(params, "--get " + q(key))?
    if out.code == 0 { return Ok(Some(out.stdout.trim())) }
    if out.code == 1 { return Ok(None) }
    Err("git config --get " + key + " failed: " + out.stderr.trim())
}

fn cfg_get_all(params: Value, key: string) -> Result[List[string], string] {
    let out = git(params, "--get-all " + q(key))?
    if out.code == 1 { return Ok([]) }
    if out.code != 0 { return Err("git config --get-all " + key + " failed: " + out.stderr.trim()) }
    let vals: List[string] = []
    for line in out.stdout.split("\n") {
        if line.trim() != "" { vals.push(line.trim()) }
    }
    Ok(vals)
}

// git creates the config file itself, but not the directory holding it.
fn ensure_parent(params: Value) -> Result[unit, string] {
    let h = param_str(params, "home", "")
    if h != "" { fs::mkdir(h)? }
    Ok(())
}

fn cfg_set(params: Value, key: string, value: string) -> Result[unit, string] {
    ensure_parent(params)?
    let out = git(params, "--replace-all " + q(key) + " " + q(value))?
    if out.success { return Ok(()) }
    Err("git config --replace-all " + key + " failed: " + out.stderr.trim())
}

fn cfg_add(params: Value, key: string, value: string) -> Result[unit, string] {
    ensure_parent(params)?
    let out = git(params, "--add " + q(key) + " " + q(value))?
    if out.success { return Ok(()) }
    Err("git config --add " + key + " failed: " + out.stderr.trim())
}

// exit 5 = the key was already gone, which is the converged state.
fn cfg_unset(params: Value, key: string) -> Result[unit, string] {
    let out = git(params, "--unset-all " + q(key))?
    if out.success || out.code == 5 { return Ok(()) }
    Err("git config --unset-all " + key + " failed: " + out.stderr.trim())
}

// Drop one occurrence of a multi-valued key, matching the value literally
// rather than as a regex. --fixed-value has to precede --unset: after it,
// git counts it as a positional and rejects the argument count.
fn cfg_unset_value(params: Value, key: string, value: string) -> Result[unit, string] {
    let out = git(params, "--fixed-value --unset " + q(key) + " " + q(value))?
    if out.success || out.code == 5 { return Ok(()) }
    Err("git config --unset " + key + " failed: " + out.stderr.trim())
}

// Fold git's boolean spellings so a config holding "yes" does not churn
// against a desired "true". Comparison only — never what gets written.
fn norm(v: string) -> string {
    let l = v.to_lower()
    if l == "true" || l == "yes" || l == "on" || l == "1" { return "true" }
    if l == "false" || l == "no" || l == "off" || l == "0" { return "false" }
    v
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let have = cfg_get(params, "alias." + name)?
    if !want_present(params)? {
        if have.is_none() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let command = param_str(params, "command", "")
    if command == "" { return Err("missing 'command' parameter") }
    // Compared literally, not through norm(): an alias is arbitrary text.
    if have.unwrap_or("") == command { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let key = "alias." + name
    if !want_present(params)? {
        log::info("removing " + key)
        cfg_unset(params, key)?
        return Ok(ApplyResult::Success)
    }
    let command = param_str(params, "command", "")
    if command == "" { return Err("missing 'command' parameter") }
    log::info("setting " + key)
    cfg_set(params, key, command)?
    Ok(ApplyResult::Success)
}
