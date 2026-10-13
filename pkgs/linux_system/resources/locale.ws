use value
use fs
use log
use shell
use common

// Two ways a locale gets built:
//   locale-gen (Debian, Ubuntu, Arch): enabled by a "name charset" line in
//     /etc/locale.gen, then compiled by locale-gen.
//   localedef (RHEL, Fedora and anything else with glibc but no
//     locale-gen): compiled straight into the locale archive.
// Without either tool there is nothing that can make a locale exist, so
// that is an error rather than a file edit reported as success.

fn validate(params: Value) -> Result[unit, string] {
    for key in ["name", "charset"] {
        let v = common::param_str(params, key, if key == "charset" { "UTF-8" } else { "" })
        if v == "" { return Err("missing '" + key + "' parameter") }
        common::one_line(key, v)?
        if common::has_space(v) || v.contains("/") || v.starts_with("-") || v.starts_with("#") {
            return Err("invalid locale " + key + " '" + v + "'")
        }
    }
    Ok(())
}

fn gen_line(params: Value) -> string {
    common::param_str(params, "name", "") + " " + common::param_str(params, "charset", "UTF-8")
}

// The spelling `locale -a` prints: the codeset lower-cased without
// punctuation (en_AU.UTF-8 -> en_AU.utf8), any @modifier kept.
fn normalized(name: string) -> string {
    let at = name.split("@")
    let base = at[0]
    let modifier = if at.len() > 1 { "@" + at[1] } else { "" }
    let dot = base.split(".")
    if dot.len() < 2 { return base + modifier }
    let codeset = dot[1].to_lower().replace("-", "").replace("_", "")
    dot[0] + "." + codeset + modifier
}

fn generated(name: string) -> Result[bool, string] {
    if !common::on_path("locale") { return Ok(false) }
    let out = common::output("locale -a", "locale -a")?
    let want = normalized(name)
    Ok(out.stdout.split("\n").any(|l| l.trim() == want || l.trim() == name))
}

fn gen_text() -> string {
    if fs::is_file("/etc/locale.gen") { fs::read("/etc/locale.gen").unwrap_or("") } else { "" }
}

// Enabled means a whole, uncommented line equal to "name charset".
fn enabled(text: string, line: string) -> bool {
    text.split("\n").any(|l| l.trim() == line)
}

fn uncommented(t: string) -> string { t.slice(1, t.len()).trim() }

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
        if !done && t.starts_with("#") && uncommented(t) == line {
            out = out + line + "\n"
            done = true
            continue
        }
        out = out + l + "\n"
    }
    if !done { out = out + line + "\n" }
    out
}

// Disable the locale by commenting its line out, the way the stock file
// lists every locale it does not build.
fn commented_out(text: string, line: string) -> string {
    let lines = text.split("\n")
    let out = ""
    for i in 0..lines.len() {
        let l = lines[i]
        if i == lines.len() - 1 && l == "" { continue }
        if l.trim() == line { out = out + "# " + line + "\n" } else { out = out + l + "\n" }
    }
    out
}

fn use_locale_gen() -> bool { common::on_path("locale-gen") }

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let name = common::param_str(params, "name", "")
    let present = common::want_present(params)?
    if use_locale_gen() {
        let on = enabled(gen_text(), gen_line(params))
        if !present { return if on { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) } }
        if on && generated(name)? { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if generated(name)? == present { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let name = common::param_str(params, "name", "")
    let charset = common::param_str(params, "charset", "UTF-8")
    let present = common::want_present(params)?
    let line = gen_line(params)
    if use_locale_gen() {
        let text = gen_text()
        if present && !enabled(text, line) {
            log::info("enabling " + line + " in /etc/locale.gen")
            common::write_atomic("/etc/locale.gen", with_line(text, line))?
        } else if !present && enabled(text, line) {
            log::info("commenting out " + line + " in /etc/locale.gen")
            common::write_atomic("/etc/locale.gen", commented_out(text, line))?
        }
        common::run("locale-gen", "locale-gen")?
        return Ok(ApplyResult::Success)
    }
    if !common::on_path("localedef") {
        return Err("cannot manage locales here: neither locale-gen nor localedef is installed")
    }
    let input = name.split("@")[0].split(".")[0] + if name.contains("@") { "@" + name.split("@")[1] } else { "" }
    let pack = "glibc-langpack-" + input.split("_")[0]
    if present {
        log::info("localedef " + name)
        let cmd = "localedef -i " + common::q(input) + " -f " + common::q(charset) + " -- " + common::q(name)
        if let Err(e) = common::run("localedef", cmd) {
            return Err(e + " (the locale sources may be missing: install " + pack + " or glibc-locale-source)")
        }
        return Ok(ApplyResult::Success)
    }
    log::info("deleting " + name + " from the locale archive")
    let out = shell::bash("localedef --delete-from-archive -- " + common::q(normalized(name)), Value::Null)?
    if generated(name)? {
        let why = if out.success { "it is installed outside the locale archive" } else { common::cmd_err("localedef --delete-from-archive", out) }
        return Err("cannot remove " + name + ": " + why + "; a langpack locale goes with its package (" + pack + ")")
    }
    Ok(ApplyResult::Success)
}
