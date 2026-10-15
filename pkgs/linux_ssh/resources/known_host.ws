use value
use common
use fs
use path

// A known_hosts entry as [marker, hosts, type, blob]: marker is
// "@cert-authority", "@revoked" or "". None for blanks, comments and
// anything else.
fn parse_entry(line: string) -> Option[List[string]] {
    let s = line.trim()
    if s == "" || s.starts_with("#") { return None }
    let f = common::split_field(s)
    let marker = ""
    if f.get(0).unwrap_or("").starts_with("@") {
        marker = f.get(0).unwrap_or("")
        f = common::split_field(f.get(1).unwrap_or(""))
    }
    let hosts = f.get(0).unwrap_or("")
    let t = common::split_field(f.get(1).unwrap_or(""))
    let kind = t.get(0).unwrap_or("")
    let blob = common::split_field(t.get(1).unwrap_or("")).get(0).unwrap_or("")
    if hosts == "" || !common::is_key_type(kind) || !common::is_base64(blob) { return None }
    Some([marker, hosts, kind, blob])
}

// The same entry: marker, host list, key type and blob all equal. A
// different comment is the same entry with stale text.
fn same_entry(a: List[string], b: List[string]) -> bool {
    a.get(0) == b.get(0) && a.get(1) == b.get(1) && a.get(2) == b.get(2) && a.get(3) == b.get(3)
}

// Whether a plain (unhashed) host list names `name`, bare or as [name]:port.
fn names_host(hosts: string, name: string) -> bool {
    for h in hosts.split(",") {
        if h == name || h.starts_with("[" + name + "]:") { return true }
    }
    false
}

fn validate(params: Value) -> Result[unit, string] {
    for k in ["name", "key", "home", "path"] { common::one_line(k, common::param_str(params, k, ""))? }
    let name = common::param_str(params, "name", "")
    if name.contains(" ") || name.contains("\t") || name.contains(",") {
        return Err("'name' must be a single host name")
    }
    let key = common::param_str(params, "key", "").trim()
    if key != "" && parse_entry(key).is_none() {
        return Err("'key' is not a known_hosts line ([marker] hosts type base64 [comment])")
    }
    if common::want_present(params)? {
        if key == "" { return Err("missing 'key' parameter") }
    } else if key == "" && name == "" {
        return Err("removal needs 'key', 'name' or both")
    }
    let p = common::param_str(params, "path", "")
    if p != "" && !p.starts_with("/") { return Err("'path' must be an absolute path") }
    let h = common::param_str(params, "home", "")
    if h != "" { common::valid_home(h)? }
    Ok(())
}

// [file, owner-managed .ssh dir or ""]. Without `path` or `home` the file
// is in the home of the user this runs as, from its passwd entry.
fn target(params: Value) -> Result[List[string], string] {
    let p = common::param_str(params, "path", "")
    if p != "" { return Ok([p, ""]) }
    let h = common::param_str(params, "home", "")
    let home = if h != "" { h } else { common::user_home(common::current_user()?)? }
    let dir = path::join(home, ".ssh")
    Ok([path::join(dir, "known_hosts"), dir])
}

// Whether a line goes: it is the wanted entry with other text, a duplicate
// of it, an older key of the same type for `name` (rotation), or, when
// removing, the entry itself or any entry for `name`.
fn rewrite(text: string, params: Value) -> Result[string, string] {
    let present = common::want_present(params)?
    let key = common::param_str(params, "key", "").trim()
    let name = common::param_str(params, "name", "")
    let want = parse_entry(key)
    let lines = if text == "" { [] } else { text.split("\n") }
    if text.ends_with("\n") { let trailing = lines.pop() }
    let out = []
    let placed = !present
    for line in lines {
        let drop = false
        let keep_as_want = false
        if let Some(e) = parse_entry(line) {
            if let Some(w) = want {
                if same_entry(e, w) {
                    if present && !placed { keep_as_want = true } else { drop = true }
                } else if name != "" && names_host(e.get(1).unwrap_or(""), name) && e.get(0) == w.get(0) {
                    // the same host with another key: of the same type it
                    // is the rotated-out key, replaced where it stands;
                    // when removing by name, any key goes
                    if !present {
                        drop = true
                    } else if e.get(2) == w.get(2) {
                        if !placed { keep_as_want = true } else { drop = true }
                    }
                }
            } else if name != "" && names_host(e.get(1).unwrap_or(""), name) {
                drop = true
            }
        }
        if keep_as_want {
            out.push(key)
            placed = true
        } else if !drop {
            out.push(line)
        }
    }
    if !placed { out.push(key) }
    Ok(if out.is_empty() { "" } else { out.join("\n") + "\n" })
}

fn read_text(p: string) -> Result[string, string] {
    if !fs::is_file(p) { return Ok("") }
    fs::read(p)
}

// The owner of the home a .ssh dir sits in, as uid:gid.
fn home_owner(dir: string) -> Result[string, string] {
    let s = common::stat_line(path::parent(dir))?
    if s == "" { return Err("home directory " + path::parent(dir) + " does not exist") }
    Ok(s.split(" ").get(1).unwrap_or(""))
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let t = target(params)?
    let p = t.get(0).unwrap_or("")
    let dir = t.get(1).unwrap_or("")
    let present = common::want_present(params)?
    if !fs::is_file(p) {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let text = if let Ok(x) = read_text(p) { x } else { return Ok(CheckResult::NotConfigured) }
    if rewrite(text, params)? != text { return Ok(CheckResult::NotConfigured) }
    if present && dir != "" {
        let owner = home_owner(dir)?
        if common::stat_line(dir)? != "700 " + owner { return Ok(CheckResult::NotConfigured) }
        if !common::stat_line(p)?.ends_with(" " + owner) { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    let t = target(params)?
    let p = t.get(0).unwrap_or("")
    let dir = t.get(1).unwrap_or("")
    let present = common::want_present(params)?
    if !present && !fs::is_file(p) { return Ok(ApplyResult::Success) }
    let text = read_text(p)?
    let next = rewrite(text, params)?
    if present && !fs::is_dir(path::parent(p)) { fs::mkdir(path::parent(p))? }
    if next != text || !fs::is_file(p) { common::write_atomic(p, next)? }
    if present && dir != "" {
        // the agent runs as root: hand what it created back to the home's
        // owner, as ssh itself would have created it
        let owner = home_owner(dir)?
        common::run("securing " + dir, "chmod 700 -- " + common::q(dir))?
        common::chown_ids(dir, owner)?
        common::chown_ids(p, owner)?
    }
    Ok(ApplyResult::Success)
}
