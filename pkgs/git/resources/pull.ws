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

fn section() -> string { "pull" }

fn keys() -> List[string] { ["rebase", "ff", "autoStash", "octopus", "twohead"] }

// ---------------------------------------------------------------------------
// Section-resource machinery — also byte-identical across the section
// scripts. Each of those declares only `keys()` (git's canonical spelling)
// and `hyphenated()` (the keys whose symbol values carry a hyphen). The
// legal values themselves live in package.wcl, where config-weave
// validates them and the docs list them.
// ---------------------------------------------------------------------------

// A typed param rendered as the text git stores. None = the step omitted
// the param, which means "leave this setting alone" — the only way a bool
// or int param can express that, since a declared default would instead
// mean "set it to false" / "set it to 0".
fn to_cfg(params: Value, name: string) -> Option[string] {
    if let Some(v) = params.get(name) {
        if let Some(s) = v.as_string() { return Some(s) }
        if let Some(b) = v.as_bool() {
            if b { return Some("true") }
            return Some("false")
        }
        if let Some(i) = v.as_int() { return Some(json::to_string(Value::Int(i))) }
    }
    None
}

// "signingKey" -> "signing_key". Params keep the repo's snake_case naming
// while `keys()` carries git's canonical spelling, so git's own casing is
// what lands in the file. Requires keys() entries to be lowerCamelCase with
// no consecutive capitals (which is why core.protectNTFS is not exposed).
fn snake(k: string) -> string {
    let out = k
    for u in ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
              "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"] {
        out = out.replace(u, "_" + u.to_lower())
    }
    out
}

// config-weave validates a symbol param against the `symbol` values the
// package declares, so all that is left here is spelling: WCL symbols
// cannot contain hyphens — the lexer stops at [A-Za-z0-9_] — so git's
// "on-demand" is declared :on_demand and the hyphen put back here. No
// legal value of these keys contains an underscore, so the substitution
// is unambiguous.
fn hyphenated() -> List[string] { [] }

// The [git key, desired text] pairs this step actually asks for. Params the
// step omitted are absent from `params` and so are skipped entirely.
fn desired_pairs(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    for key in keys() {
        let name = snake(key)
        if let Some(raw) = to_cfg(params, name) {
            let value = raw
            if hyphenated().contains(key) { value = raw.replace("_", "-") }
            out.push([section() + "." + key, value])
        }
    }
    Ok(out)
}

// An explicit empty string reads back as "unset" and so is a no-op here;
// use git.config_entry with ensure = :absent to remove a key.
fn check(params: Value) -> Result[CheckResult, string] {
    for pair in desired_pairs(params)? {
        let key = pair.get(0).unwrap_or("")
        let want = pair.get(1).unwrap_or("")
        let have = cfg_get(params, key)?
        if norm(have.unwrap_or("")) != norm(want) { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    for pair in desired_pairs(params)? {
        let key = pair.get(0).unwrap_or("")
        let want = pair.get(1).unwrap_or("")
        let have = cfg_get(params, key)?
        if norm(have.unwrap_or("")) != norm(want) {
            log::info("setting " + key + " = " + want)
            cfg_set(params, key, want)?
        }
    }
    Ok(ApplyResult::Success)
}
