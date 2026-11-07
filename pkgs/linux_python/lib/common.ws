use value
use shell
use json
use regex
use fs
use path

// Helpers for linux_python's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// A failed command's error: stderr, else stdout, always with the exit code.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

// ---------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------

// A distribution name as PEP 508 defines it: letters and digits, with '.',
// '_' and '-' only between them. That rules out an option ('-...'), a URL,
// a path, a version specifier, extras and an environment marker, so the
// name can only ever be read by pip as a project name.
fn dist_name(v: string) -> Result[unit, string] {
    if v == "" { return Err("missing 'name' parameter") }
    if !regex::is_match("^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$", v) {
        return Err("invalid 'name' '" + v + "': a distribution name only (letters, digits, and '.', '_' or '-' between them), not a URL, path, version specifier or pip option")
    }
    Ok(())
}

// An exact PEP 440 version such as 1.2.3, 2!1.0, 1.0rc1, 1.0.post2 or
// 1.0+local.7. Specifiers and wildcards (>=, ~=, ==, *, commas) are refused:
// `version` is an exact pin.
fn exact_version(v: string) -> Result[unit, string] {
    if !regex::is_match("^[A-Za-z0-9]([A-Za-z0-9.!+_-]*[A-Za-z0-9])?$", v) {
        return Err("invalid 'version' '" + v + "': an exact version only (e.g. 1.4.2), not a range, specifier or wildcard")
    }
    Ok(())
}

// An executable name looked up on PATH (pip3) or an absolute path
// (/opt/tool/bin/pip). No whitespace or shell syntax: it is one argv word.
fn executable(v: string) -> Result[unit, string] {
    if v == "" { return Err("'executable' must not be empty") }
    if v.starts_with("-") { return Err("'executable' must not start with '-'") }
    if !regex::is_match("^[A-Za-z0-9._/+-]+$", v) {
        return Err("invalid 'executable' '" + v + "': an executable name or absolute path, letters, digits, '.', '_', '+', '-' and '/' only")
    }
    if v.contains("/") && !v.starts_with("/") { return Err("'executable' '" + v + "' must be a bare name or an absolute path") }
    if v.split("/").any(|p| p == "..") { return Err("'executable' must not contain '..'") }
    Ok(())
}

// An existing virtual environment, given as an absolute path. It is never
// created: a missing one, or one without bin/python, is an error.
fn virtualenv(v: string) -> Result[unit, string] {
    if !v.starts_with("/") { return Err("'virtualenv' '" + v + "' must be an absolute path") }
    if v.split("/").any(|p| p == "..") { return Err("'virtualenv' must not contain '..'") }
    if v.contains("\n") || v.contains("\r") { return Err("'virtualenv' must not contain line breaks") }
    if !fs::is_dir(v) { return Err("virtualenv " + v + " does not exist (it is not created here)") }
    if !fs::exists(path::join(v, "bin/python")) { return Err(v + " is not a virtual environment: it has no bin/python") }
    Ok(())
}

// ---------------------------------------------------------------------
// Running pip
// ---------------------------------------------------------------------

// The pip a step uses, described for messages and handed to bash through
// the environment (never through shell text): <venv>/bin/python -m pip, or
// the executable.
struct Pip {
    label: string,
    var: string,
    val: string,
}

fn select(params: Value) -> Result[Pip, string] {
    let venv = param_str(params, "virtualenv", "")
    let exe = param_str(params, "executable", "pip3")
    if venv != "" {
        if exe != "pip3" {
            return Err("set either 'virtualenv' or 'executable', not both: a virtualenv always uses <virtualenv>/bin/python -m pip")
        }
        virtualenv(venv)?
        let py = path::join(venv, "bin/python")
        return Ok(Pip { label: py + " -m pip", var: "CW_PIP_PY", val: py })
    }
    executable(exe)?
    Ok(Pip { label: exe, var: "CW_PIP_EXE", val: exe })
}

// pip never prompts, never checks PyPI for a newer pip, and does not warn
// about running as root. Every other pip setting (index, find-links,
// PEP 668) is the environment's own and is left as it is.
// `args` is fixed shell text; `req` (a requirement, or "") reaches pip as
// the last argument through $CW_PIP_REQ, after `--`.
fn pip(p: Pip, args: string, req: string) -> Result[CmdOutput, string] {
    let vars: Map[string, Value] = #{ "CW_PIP_REQ": Value::String(req) }
    vars.insert(p.var, Value::String(p.val))
    vars.insert("PIP_DISABLE_PIP_VERSION_CHECK", Value::String("1"))
    vars.insert("PIP_NO_INPUT", Value::String("1"))
    vars.insert("PIP_ROOT_USER_ACTION", Value::String("ignore"))
    vars.insert("LC_ALL", Value::String("C"))
    let cmd = if p.var == "CW_PIP_PY" { "\"$CW_PIP_PY\" -m pip " } else { "\"$CW_PIP_EXE\" " }
    let tail = if req != "" { " -- \"$CW_PIP_REQ\"" } else { "" }
    shell::bash(cmd + args + tail, Value::Map(#{ "env": Value::Map(vars) }))
}

// PEP 503 normalized name: runs of '-', '_' and '.' are one '-', lowercase.
fn normalize(name: string) -> string {
    regex::replace("[-_.]+", name.to_lower(), "-")
}

// The installed version of a distribution in the selected environment, or
// "" when it is not installed. Reads installed metadata with `pip list`,
// which contacts no index, and matches the normalized name exactly.
fn installed(p: Pip, name: string) -> Result[string, string] {
    let out = pip(p, "list --format=json", "")?
    if !out.success { return Err(cmd_err(p.label + " list", out)) }
    let parsed = json::parse(out.stdout.trim())
    let data = match parsed { Ok(v) => v, Err(e) => return Err(p.label + " list printed no JSON: " + e) }
    let want = normalize(name)
    if let Some(items) = data.as_list() {
        for d in items {
            if normalize(param_str(d, "name", "")) == want { return Ok(param_str(d, "version", "")) }
        }
        return Ok("")
    }
    Err(p.label + " list did not print a list")
}
