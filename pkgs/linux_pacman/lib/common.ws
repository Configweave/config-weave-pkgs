use value
use fs
use shell

// Helpers shared by linux_pacman's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let out = []
    if let Some(v) = params.get(key) {
        if let Some(items) = v.as_list() {
            for i in items { if let Some(s) = i.as_string() { out.push(s) } }
        }
    }
    out
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// A failed command's error: stderr, else stdout, always with the exit code.
// pacman explains a refused removal ("breaks dependency ... required by")
// on stdout.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

fn output(what: string, cmd: string) -> Result[CmdOutput, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(out)
}

fn run(what: string, cmd: string) -> Result[unit, string] {
    let out = output(what, cmd)?
    Ok(())
}

// Values written into pacman.conf must stay on one line.
fn one_line(key: string, v: string) -> Result[unit, string] {
    if v.contains("\n") || v.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    Ok(())
}

// A name handed to pacman or sudo as an operand, or written into a
// whitespace-separated pacman.conf list: a leading '-' would be read as an
// option, and whitespace would split it in two.
fn operand(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    if v.starts_with("-") { return Err("'" + key + "' must not start with '-'") }
    if v.contains(" ") || v.contains("\t") || v.contains("\n") || v.contains("\r") {
        return Err("'" + key + "' must not contain whitespace")
    }
    Ok(())
}

// pacman as every resource runs it. pacman fails at once when another
// pacman holds /var/lib/pacman/db.lck, which another linux_pacman resource
// type may, running in the same play; pacman has no wait option, so wait
// up to five minutes for the lock file to go first.
fn pacman(args: string) -> string {
    "i=0; while [ -e /var/lib/pacman/db.lck ] && [ $i -lt 300 ]; do sleep 1; i=$((i+1)); done; pacman --noconfirm " + args
}

// pacman -T prints the targets no installed package satisfies, so exit 0
// means name is a package or something an installed package provides.
fn satisfied(name: string) -> Result[bool, string] {
    Ok(shell::bash("pacman -T " + q(name) + " >/dev/null 2>&1", Value::Null)?.success)
}

fn lines(text: string) -> List[string] {
    let out = []
    for l in text.split("\n") { if l.trim() != "" { out.push(l.trim()) } }
    out
}

// Installed members of the group name; empty when it is not a group.
fn group_installed(name: string) -> Result[List[string], string] {
    Ok(lines(shell::bash("pacman -Qgq " + q(name) + " 2>/dev/null", Value::Null)?.stdout))
}

// Members of the group name in the sync databases that are not installed.
fn group_missing(name: string) -> Result[List[string], string] {
    let out = shell::bash("pacman -Sgq " + q(name) + " 2>/dev/null | while read -r p; do pacman -Q \"$p\" >/dev/null 2>&1 || echo \"$p\"; done", Value::Null)?
    Ok(lines(out.stdout))
}

// Is name present: a package, something an installed package provides, or
// a group with every member the sync databases list installed.
fn present(name: string) -> Result[bool, string] {
    if satisfied(name)? { return Ok(true) }
    if group_installed(name)?.len() == 0 { return Ok(false) }
    Ok(group_missing(name)?.len() == 0)
}

fn absent(name: string) -> Result[bool, string] {
    Ok(!satisfied(name)? && group_installed(name)?.len() == 0)
}

// Remove whatever makes name present. pacman -R takes a package or a group
// but not a provided name, so a provided name is resolved to the installed
// packages behind it first (pacman -Qq resolves provides).
fn remove(name: string) -> Result[unit, string] {
    let targets = if group_installed(name)?.len() > 0 {
        q(name)
    } else {
        let owners = lines(shell::bash("pacman -Qq " + q(name) + " 2>/dev/null", Value::Null)?.stdout)
        if owners.len() == 0 { return Err("cannot find the installed package that provides '" + name + "'") }
        owners.map(|o| q(o)).join(" ")
    }
    run("pacman -R", pacman("-R " + targets))
}

// A user the AUR helper runs as: a plain login name.
fn user_name(v: string) -> Result[unit, string] {
    operand("user", v)?
    if !v.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.') {
        return Err("invalid 'user' '" + v + "'")
    }
    Ok(())
}

// Run cmd as user from their home directory, with HOME set to it: yay and
// paru keep their cache and makepkg its build directory under HOME, and
// refuse to run as root.
fn as_user(user: string, cmd: string) -> string {
    "sudo -H -u " + q(user) + " -- sh -c " + q("cd \"$HOME\" && " + cmd)
}

// Resolve the AUR helper on the build user's PATH (so /usr/local/bin
// counts): :yay and :paru must be there, :auto takes yay, then paru.
fn helper(params: Value, user: string) -> Result[string, string] {
    let h = param_str(params, "helper", "auto")
    if h != "auto" && h != "yay" && h != "paru" {
        return Err("invalid 'helper' value '" + h + "' (expected :auto, :yay or :paru)")
    }
    let candidates = if h == "auto" { ["yay", "paru"] } else { [h] }
    for c in candidates {
        if shell::bash(as_user(user, "command -v " + c) + " >/dev/null 2>&1", Value::Null)?.success { return Ok(c) }
    }
    Err("no AUR helper found on " + user + "'s PATH (looked for " + candidates.join(" and ") + ")")
}

fn pacman_conf() -> string { "/etc/pacman.conf" }

fn read_conf() -> Result[string, string] {
    if !fs::is_file(pacman_conf()) { return Err(pacman_conf() + " does not exist") }
    fs::read(pacman_conf())
}

// A section header line ("[core]"), or "" for any other line.
fn header(line: string) -> string {
    let t = line.trim()
    if t.starts_with("[") && t.ends_with("]") { return t.slice(1, t.len() - 1).trim() }
    ""
}

// "Key = Value" with the spacing normalised, or "" for a blank or comment.
fn setting(line: string) -> string {
    let t = line.trim()
    if t == "" || t.starts_with("#") { return "" }
    if let Some(i) = t.find("=") { return t.slice(0, i).trim() + " = " + t.slice(i + 1, t.len()).trim() }
    t
}

// Text split into lines, without the empty piece after a final newline.
fn conf_lines(text: string) -> List[string] {
    let ls = text.split("\n")
    if ls.len() > 0 && ls[ls.len() - 1] == "" { let last = ls.pop() }
    ls
}

fn conf_text(ls: List[string]) -> string {
    if ls.len() == 0 { "" } else { ls.join("\n") + "\n" }
}
