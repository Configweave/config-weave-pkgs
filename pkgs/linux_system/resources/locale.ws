use value
use fs
use shell

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

fn gen_line(params: Value) -> Result[string, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    Ok(name + " " + param_str(params, "charset", "UTF-8"))
}

fn has_line(text: string, line: string) -> bool {
    for l in text.split("\n") { if l.trim() == line { return true } }
    false
}

// Enable the locale: uncomment a "# name charset" line when one exists,
// otherwise append the line.
fn with_line(text: string, line: string) -> string {
    let lines = text.split("\n")
    let out = ""
    let done = false
    for i in 0..lines.len() {
        let l = lines[i]
        if i == lines.len() - 1 && l == "" { continue }
        let t = l.trim()
        if !done && t.starts_with("#") && t.slice(1, t.len()).trim() == line {
            out = out + line + "\n"
            done = true
            continue
        }
        out = out + l + "\n"
    }
    if !done { out = out + line + "\n" }
    out
}

fn without_line(text: string, line: string) -> string {
    let lines = text.split("\n")
    let out = ""
    for i in 0..lines.len() {
        let l = lines[i]
        if i == lines.len() - 1 && l == "" { continue }
        if l.trim() == line { continue }
        out = out + l + "\n"
    }
    out
}

fn run_locale_gen() -> Result[unit, string] {
    if !fs::exists("/usr/sbin/locale-gen") && !fs::exists("/usr/bin/locale-gen") { return Ok(()) }
    let out = shell::bash("locale-gen", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let line = gen_line(params)?
    let text = if fs::is_file("/etc/locale.gen") { fs::read("/etc/locale.gen")? } else { "" }
    if has_line(text, line) == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let line = gen_line(params)?
    let text = if fs::is_file("/etc/locale.gen") { fs::read("/etc/locale.gen")? } else { "" }
    if want_present(params)? {
        if !has_line(text, line) { fs::write("/etc/locale.gen", with_line(text, line))? }
    } else {
        if !has_line(text, line) { return Ok(ApplyResult::Success) }
        fs::write("/etc/locale.gen", without_line(text, line))?
    }
    run_locale_gen()?
    Ok(ApplyResult::Success)
}
