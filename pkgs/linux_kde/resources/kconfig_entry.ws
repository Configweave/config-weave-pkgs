use value
use common
use fs
use json
use path

fn hex_digits() -> string { "0123456789abcdef" }

fn hex2(n: int) -> string {
    let h = hex_digits()
    h.slice(n / 16, n / 16 + 1) + h.slice(n % 16, n % 16 + 1)
}

// The one-character string for an ASCII code point.
fn ascii(n: int) -> string {
    if let Ok(v) = json::parse("\"\\u00" + hex2(n) + "\"") { if let Some(s) = v.as_string() { return s } }
    ""
}

fn has_control(v: string) -> bool {
    for n in 0..32 { if v.contains(ascii(n)) { return true } }
    v.contains(ascii(127))
}

// ---- KConfig escaping -----------------------------------------------------
//
// Mirrors KConfigIniBackend::stringToPrintable for values: backslash, \n, \t
// and \r get backslash escapes, every other control character becomes \xNN,
// and a leading or trailing space becomes \s (KConfig trims the raw text).

fn escape_value(v: string) -> string {
    let s = v.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    for n in 0..32 {
        if n != 9 && n != 10 && n != 13 { s = s.replace(ascii(n), "\\x" + hex2(n)) }
    }
    s = s.replace(ascii(127), "\\x7f")
    if s.starts_with(" ") { s = "\\s" + s.slice(1, s.len()) }
    if s.ends_with(" ") { s = s.slice(0, s.len() - 1) + "\\s" }
    s
}

fn hex_val(c: string) -> int {
    if let Some(i) = hex_digits().find(c.to_lower()) { return i }
    -1
}

// Mirrors KConfigIniBackend::printableToString: the value KConfig reads from
// the raw text after '='. None when the text holds something this cannot
// decode exactly (an invalid escape, or a \xNN byte above 0x7f); the caller
// then treats the line as different and rewrites it.
fn unescape_value(raw: string) -> Option[string] {
    if !raw.contains("\\") { return Some(raw) }
    let s = raw.trim()
    let out = ""
    let i = 0
    let n = s.len()
    while i < n {
        let c = s.slice(i, i + 1)
        if c != "\\" {
            out = out + c
            i = i + 1
            continue
        }
        i = i + 1
        if i >= n { return Some(out + "\\") }
        let e = s.slice(i, i + 1)
        if e == "s" { out = out + " " }
        else if e == "t" { out = out + "\t" }
        else if e == "n" { out = out + "\n" }
        else if e == "r" { out = out + "\r" }
        else if e == "\\" { out = out + "\\" }
        else if e == ";" || e == "," { out = out + "\\" + e }
        else if e == "x" {
            if i + 2 >= n { return None }
            let hi = hex_val(s.slice(i + 1, i + 2))
            let lo = hex_val(s.slice(i + 2, i + 3))
            if hi < 0 || lo < 0 || hi > 7 { return None }
            out = out + ascii(hi * 16 + lo)
            i = i + 2
        } else { return None }
        i = i + 1
    }
    Some(out)
}

// ---- params ---------------------------------------------------------------

struct Entry {
    path: string,
    home: string,
    section: string,
    key: string,
    present: bool,
    value: string,
}

fn check_name(what: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + what + "' parameter") }
    if has_control(v) { return Err("'" + what + "' must not contain line breaks or other control characters") }
    Ok(())
}

fn entry(params: Value) -> Result[Entry, string] {
    let f = common::param_str(params, "file", "")
    if f == "" { return Err("missing 'file' parameter") }
    if f.starts_with("/") || f.contains("..") || has_control(f) {
        return Err("'file' must be a relative path under ~/.config without '..' (got '" + f + "')")
    }
    let group = common::param_str(params, "group", "")
    let subgroup = common::param_str(params, "subgroup", "")
    let key = common::param_str(params, "key", "")
    check_name("group", group)?
    if subgroup != "" { check_name("subgroup", subgroup)? }
    check_name("key", key)?
    if group.contains("[") || group.contains("]") || subgroup.contains("[") || subgroup.contains("]") {
        return Err("'group' and 'subgroup' must not contain '[' or ']'")
    }
    if key.contains("=") { return Err("'key' must not contain '='") }
    if key != key.trim() || key.starts_with("#") || key.starts_with("[") {
        return Err("'key' must not start with '#' or '[' or have leading or trailing whitespace")
    }
    let present = common::want_present(params)?
    let value = ""
    if present {
        // No declared default, so an unset value is told apart from "" (which
        // writes `key=`).
        if let Some(v) = params.get("value") { value = v.as_string().unwrap_or("") } else {
            return Err("'value' is required when ensure = :present")
        }
    }
    let home = common::home(params)
    let section = if subgroup == "" { "[" + group + "]" } else { "[" + group + "][" + subgroup + "]" }
    Ok(Entry { path: home + "/.config/" + f, home: home, section: section, key: key, present: present, value: value })
}

// ---- the file -------------------------------------------------------------

fn lines_of(text: string) -> List[string] {
    if text == "" { return [] }
    let lines = text.split("\n")
    if text.ends_with("\n") { let dropped = lines.pop() }
    lines
}

// KConfig trims a line, skips blanks and '#' comments, and splits an entry
// at the first '=' with the key trimmed.
fn line_key(t: string) -> Option[string] {
    if t == "" || t.starts_with("#") || t.starts_with("[") { return None }
    if let Some(eq) = t.find("=") { return Some(t.slice(0, eq).trim()) }
    None
}

fn line_value(t: string) -> string {
    if let Some(eq) = t.find("=") { t.slice(eq + 1, t.len()).trim() } else { "" }
}

// Insert at the end of the section just walked: after its last non-blank
// line, so the blank line separating it from the next section stays put.
fn insert_at_section_end(out: List[string], line: string) {
    let at = out.len()
    while at > 0 && out.get(at - 1).unwrap_or("x").trim() == "" { at = at - 1 }
    out.insert(at, line)
}

// One walk over the file for both states. The first matching key line in the
// section is kept verbatim when its decoded value already matches, otherwise
// rewritten; any later duplicate is dropped (KConfig would use the last one).
// For :absent every matching line is dropped. The section header stays even
// when it ends up empty.
fn render(text: string, e: Entry) -> List[string] {
    let wanted = e.key + "=" + escape_value(e.value)
    let out = []
    let in_section = false
    let seen = false
    let done = false
    for line in lines_of(text) {
        let t = line.trim()
        if t.starts_with("[") {
            if in_section && e.present && !done {
                insert_at_section_end(out, wanted)
                done = true
            }
            in_section = t == e.section
            if in_section { seen = true }
            out.push(line)
            continue
        }
        if in_section {
            if let Some(k) = line_key(t) {
                if k == e.key {
                    if e.present && !done {
                        let same = if let Some(v) = unescape_value(line_value(t)) { v == e.value } else { false }
                        out.push(if same { line } else { wanted })
                        done = true
                    }
                    continue
                }
            }
        }
        out.push(line)
    }
    if e.present && !done {
        if in_section {
            insert_at_section_end(out, wanted)
        } else if !seen {
            if out.len() > 0 && out.get(out.len() - 1).unwrap_or("").trim() != "" { out.push("") }
            out.push(e.section)
            out.push(wanted)
        }
    }
    out
}

// The rendered file, or None when it is unchanged. A file without a final
// newline that needs no other change counts as unchanged.
fn changed(text: string, e: Entry) -> Option[string] {
    let before = lines_of(text)
    let after = render(text, e)
    if after.len() == before.len() {
        let same = true
        for i in 0..after.len() {
            if after.get(i).unwrap_or("") != before.get(i).unwrap_or("") { same = false }
        }
        if same { return None }
    }
    Some(if after.is_empty() { "" } else { after.join("\n") + "\n" })
}

fn uid_of(owner: string) -> string { owner.split(":").get(0).unwrap_or("") }

fn check(params: Value) -> Result[CheckResult, string] {
    let e = entry(params)?
    if !fs::is_file(e.path) {
        if e.present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // unreadable (for example not UTF-8) is drift; apply reports why
    let text = fs::read(e.path)
    if text.is_err() { return Ok(CheckResult::NotConfigured) }
    if changed(text.unwrap_or(""), e).is_some() { return Ok(CheckResult::NotConfigured) }
    if e.present && fs::is_dir(e.home) && uid_of(common::link_owner(e.path)?) != uid_of(common::owner(e.home)?) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let e = entry(params)?
    if !e.present && !fs::is_file(e.path) { return Ok(ApplyResult::Success) }
    if !fs::is_dir(e.home) { return Err("home directory " + e.home + " does not exist") }
    let home_owner = common::owner(e.home)?

    // directories this step creates, so they can be handed to home's owner
    let fresh = []
    let dir = path::parent(e.path)
    while dir != e.home && dir != "" && dir != "/" && !fs::exists(dir) {
        fresh.push(dir)
        dir = path::parent(dir)
    }
    let existed = fs::is_file(e.path)
    let text = if existed { fs::read(e.path)? } else { "" }
    if let Some(next) = changed(text, e) {
        fs::mkdir(path::parent(e.path))?
        // the agent runs as root in a user's tree: a symlink planted at the
        // path is refused, never written through
        fs::write_with(e.path, next, Value::Map(#{ "follow_symlinks": Value::Bool(false) }))?
    }
    if e.present || !existed {
        if !existed || uid_of(common::link_owner(e.path)?) != uid_of(home_owner) { fresh.push(e.path) }
    }
    for p in fresh { common::chown_ids(p, home_owner)? }
    Ok(ApplyResult::Success)
}
