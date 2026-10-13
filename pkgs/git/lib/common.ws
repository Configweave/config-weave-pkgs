use value
use fs
use shell

// git-config helpers shared by every script in the git package. Imported
// with `use common`; nothing here is package-external.
//
// Everything goes through the `git config` binary rather than editing the
// INI file directly. git owns the quoting rules (values containing #, ;, "
// or trailing whitespace), multi-valued keys, and the platform-correct
// location of the system config — none of which a hand-rolled writer got
// right. The cost is that the target must have git installed.

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

// `flags` go before the key; `--` ends option parsing, so a key can never
// be read as a switch. Values need no such guard: git config stops parsing
// options at its first positional.
fn git(params: Value, flags: string, key: string, rest: string) -> Result[CmdOutput, string] {
    let cmd = "git config " + scope_flag(params)? + " " + flags + " -- " + q(key)
    if rest != "" { return shell::run(cmd + " " + rest, git_opts(params)) }
    shell::run(cmd, git_opts(params))
}

// A failed command's error: stderr, else stdout, always with the exit code.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

// Every value of `key`, exactly as git stores it. -z ends each value with a
// NUL instead of a newline, so edge whitespace and multi-line values come
// back intact and an explicitly empty value is still one entry.
fn cfg_get_all(params: Value, key: string) -> Result[List[string], string] {
    read_all(params, key, "")
}

// Every value of `key` as git reads it for `kind`, "bool" or "int". git does
// the canonicalising ("yes", "on", "1" and a bare `key` line are all
// "true"; "1k" is "1024"), so a stored value is compared the way git itself
// interprets it. A value git cannot read as that type comes back as
// "<invalid>", which matches nothing and so counts as drift.
fn cfg_get_typed(params: Value, key: string, kind: string) -> Result[List[string], string] {
    read_all(params, key, "--type=" + kind)
}

// git exits 1 both for an unset key and for a malformed one; only the
// malformed case writes to stderr, and that is an error, not "unset".
fn read_all(params: Value, key: string, type_flag: string) -> Result[List[string], string] {
    let out = git(params, (type_flag + " -z --get-all").trim(), key, "")?
    if out.code == 1 {
        if out.stderr.trim() == "" { return Ok([]) }
        return Err(cmd_err("git config --get-all " + key, out))
    }
    if type_flag != "" && out.code == 128 && out.stderr.contains("bad ") && out.stderr.contains(" config value") {
        return Ok(["<invalid>"])
    }
    if out.code != 0 { return Err(cmd_err("git config --get-all " + key, out)) }
    let vals: List[string] = []
    let parts = out.stdout.split("\0")
    // The output ends with a NUL, so the last part is the empty remainder.
    let i = 0
    while i + 1 < parts.len() {
        vals.push(parts.get(i).unwrap_or(""))
        i = i + 1
    }
    Ok(vals)
}

// The single value of `key`; None when unset. A multi-valued key reads as
// its last value, which is the one git itself uses.
fn cfg_get(params: Value, key: string) -> Result[Option[string], string] {
    let vals = cfg_get_all(params, key)?
    if vals.is_empty() { return Ok(None) }
    Ok(vals.last())
}

// git creates the config file itself, but not the directory holding it.
fn ensure_parent(params: Value) -> Result[unit, string] {
    let h = param_str(params, "home", "")
    if h != "" { fs::mkdir(h)? }
    Ok(())
}

fn cfg_set(params: Value, key: string, value: string) -> Result[unit, string] {
    ensure_parent(params)?
    let out = git(params, "--replace-all", key, q(value))?
    if out.success { return Ok(()) }
    Err(cmd_err("git config --replace-all " + key, out))
}

fn cfg_add(params: Value, key: string, value: string) -> Result[unit, string] {
    ensure_parent(params)?
    let out = git(params, "--add", key, q(value))?
    if out.success { return Ok(()) }
    Err(cmd_err("git config --add " + key, out))
}

// exit 5 = the key was already gone, which is the converged state.
fn cfg_unset(params: Value, key: string) -> Result[unit, string] {
    let out = git(params, "--unset-all", key, "")?
    if out.success || out.code == 5 { return Ok(()) }
    Err(cmd_err("git config --unset-all " + key, out))
}

// Drop one occurrence of a multi-valued key, matching the value literally
// rather than as a regex. --fixed-value has to precede --unset: after it,
// git counts it as a positional and rejects the argument count.
fn cfg_unset_value(params: Value, key: string, value: string) -> Result[unit, string] {
    let out = git(params, "--fixed-value --unset", key, q(value))?
    if out.success || out.code == 5 { return Ok(()) }
    Err(cmd_err("git config --unset " + key, out))
}

// Fold git's word spellings of a boolean, so a symbol or string holding
// "yes" does not churn against a desired "true". Digits are left alone: in a
// bool-or-int key such as merge.log, "1" is a count, not "true".
// Comparison only — never what gets written.
fn fold_words(v: string) -> string {
    let l = v.to_lower()
    if l == "true" || l == "yes" || l == "on" { return "true" }
    if l == "false" || l == "no" || l == "off" { return "false" }
    v
}

// A config variable name: section, optional subsection, name. Section and
// name are alphanumeric or '-', and the name starts with a letter (git's
// own rules); the subsection is free text without line breaks.
fn check_key(key: string) -> Result[unit, string] {
    if key == "" { return Err("missing 'key' parameter") }
    let bad = Err("invalid key '" + key + "': expected section.name or section.subsection.name")
    if key.contains("\n") || key.contains("\r") || key.contains("\0") { return bad }
    let parts = key.split(".")
    if parts.len() < 2 { return bad }
    let name = parts.get(parts.len() - 1).unwrap_or("")
    if !valid_word(parts.get(0).unwrap_or("")) || !valid_word(name) { return bad }
    let c = name.chars().first().unwrap_or('0')
    if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) { return bad }
    Ok(())
}

fn valid_word(w: string) -> bool {
    if w == "" { return false }
    w.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-')
}
