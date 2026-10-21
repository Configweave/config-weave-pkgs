use value
use fs
use shell

// Helpers shared by linux_dnf's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// The dnf-family front-end actually present on this host, newest first.
fn dnf_bin() -> Result[string, string] {
    if fs::exists("/usr/bin/dnf5") { return Ok("dnf5") }
    if fs::exists("/usr/bin/dnf") { return Ok("dnf") }
    if fs::exists("/usr/bin/microdnf") { return Ok("microdnf") }
    if fs::exists("/usr/bin/yum") { return Ok("yum") }
    Err("no dnf-family package manager found (dnf5, dnf, microdnf or yum)")
}

// The front-end for versionlock. Deliberately not dnf_bin(): versionlock is
// a plugin for dnf5, dnf and yum, and microdnf has no equivalent, so a
// microdnf-only host is an error here rather than a fallback.
fn lock_bin() -> Result[string, string] {
    if fs::exists("/usr/bin/dnf5") { return Ok("dnf5") }
    if fs::exists("/usr/bin/dnf") { return Ok("dnf") }
    if fs::exists("/usr/bin/yum") { return Ok("yum") }
    Err("hold requires dnf5, dnf or yum with the versionlock plugin")
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

// A failed command's error: stderr, else stdout (dnf and yum report many
// failures there), always with the exit code.
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

// A distro package version follows dnf's own ordering rules (epochs,
// '~' sorting before a release, '-release'), not the npm-style ranges the
// Windows packages accept, so `version` is an exact pin. A value that reads
// as a range is refused with that reason rather than handed to dnf as a
// version that cannot exist. Only range syntax is refused: a leading
// comparison, '^' or '~' operator, '||', a space-separated set or hyphen
// range, a '*' wildcard, or a bare or trailing x part. '~' and '-' inside a
// version (1.2~rc1-3) are ordinary distro syntax.
fn exact_pin(key: string, v: string) -> Result[unit, string] {
    let t = v.trim()
    let leading = ["^", "~", ">", "<", "="].any(|op| t.starts_with(op))
    let wild = t.contains("*") || t == "x" || t == "X" || t.ends_with(".x") || t.ends_with(".X")
    if leading || wild || t.contains("||") || t.contains(" ") || t.contains("\t") {
        return Err("'" + key + "' is \"" + v + "\", a version range: ranges are not supported for distro packages, whose versions follow dnf's own rules. Pin an exact version: VERSION, VERSION-RELEASE or EPOCH:VERSION-RELEASE as dnf list shows it, e.g. 2.23-4.fc44")
    }
    Ok(())
}

// A package name or version handed to rpm or dnf as an operand: a leading
// '-' would be read as an option, and whitespace would split it in two.
fn operand(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    if v.starts_with("-") { return Err("'" + key + "' must not start with '-'") }
    if v.contains(" ") || v.contains("\t") || v.contains("\n") || v.contains("\r") {
        return Err("'" + key + "' must not contain whitespace")
    }
    Ok(())
}

// A basename joined onto an /etc directory: no '/', no '..', nothing
// hidden or option-like.
fn file_name(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    if v.starts_with(".") || v.starts_with("-") || !v.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == '+' || c == '@') {
        return Err("invalid '" + key + "' '" + v + "': use letters, digits and '_', '-', '.', '+', '@', not starting with '.' or '-'")
    }
    Ok(())
}

// The installed packages name stands for, which is what dnf install
// resolves it to: the package of that name, else every package that
// provides it as a capability such as python3dist(requests) or a file path.
// The name is tried first because not everything installed provides its
// own name: rpm 6 keeps gpg-pubkey entries outside the provides index. One
// [NAME, VERSION, VERSION-RELEASE, EPOCH:VERSION-RELEASE] per installed
// instance, so multilib and installonly packages (kernel) each get their
// own entry.
fn providers(name: string) -> Result[List[List[string]], string] {
    let qf = "--qf '%{{NAME}} %{{VERSION}} %{{RELEASE}} %{{EPOCH}}\\n' "
    let out = shell::bash("rpm -q " + qf + q(name) + " 2>/dev/null || rpm -q --whatprovides " + qf + q(name) + " 2>/dev/null", Value::Null)?
    let found = []
    if !out.success { return Ok(found) }
    for l in out.stdout.split("\n") {
        let f = l.trim().split(" ")
        if f.len() != 4 { continue }
        let vr = f[1] + "-" + f[2]
        let evr = if f[3] == "(none)" { "0:" + vr } else { f[3] + ":" + vr }
        found.push([f[0], f[1], vr, evr])
    }
    Ok(found)
}

// A version pin is VERSION, VERSION-RELEASE or EPOCH:VERSION-RELEASE.
fn version_matches(p: List[string], version: string) -> bool {
    p[1] == version || p[2] == version || p[3] == version
}

// The distinct package names among providers.
fn provider_names(found: List[List[string]]) -> List[string] {
    let names = []
    for p in found {
        if !names.contains(p[0]) { names.push(p[0]) }
    }
    names
}

fn quoted(xs: List[string]) -> string {
    let out = []
    for x in xs { out.push(q(x)) }
    out.join(" ")
}

// rpm -e --test fails, naming them, when installed packages depend on the
// ones being removed: dnf remove would silently take those too.
fn guard_dependents(names: List[string]) -> Result[unit, string] {
    let out = shell::bash("rpm -e --test --allmatches " + quoted(names), Value::Null)?
    if !out.success {
        return Err("removing " + names.join(", ") + " would also remove the packages that depend on it; remove those first or set remove_dependents = true. " + out.stderr.trim())
    }
    Ok(())
}

// The gpg-pubkey "<version>-<release>" of every key in an armored block.
// rpm derives these itself on import, so the block is imported into a
// throwaway rpmdb and read back: this works on every rpm, whether the
// version is a short key id (rpm 4) or a fingerprint (rpm 6), and with no
// gpg installed. An invalid key is an error here, before anything is
// written.
fn key_ids(content: string) -> Result[List[string], string] {
    let cmd = "d=$(mktemp -d) && trap 'rm -rf \"$d\"' EXIT && printf '%s' \"$CW_KEY\" > \"$d/key.asc\" && rpm --dbpath \"$d/db\" --initdb && rpm --dbpath \"$d/db\" --import \"$d/key.asc\" && rpm --dbpath \"$d/db\" -q gpg-pubkey --qf '%{{VERSION}}-%{{RELEASE}}\\n'"
    let out = shell::bash(cmd, Value::Map(#{ "env": Value::Map(#{ "CW_KEY": Value::String(content) }) }))?
    if !out.success { return Err(cmd_err("reading the key with rpm --import", out)) }
    let ids = []
    for l in out.stdout.split("\n") {
        if l.trim() != "" { ids.push(l.trim()) }
    }
    if ids.is_empty() { return Err("content holds no OpenPGP public key") }
    Ok(ids)
}

fn key_imported(id: string) -> Result[bool, string] {
    Ok(shell::bash("rpm -q " + q("gpg-pubkey-" + id) + " >/dev/null 2>&1", Value::Null)?.success)
}

// rpm 4.20+ deletes keys with rpmkeys --delete and deprecates erasing the
// gpg-pubkey pseudo-package; older rpm only has rpm -e.
fn delete_key(id: string) -> Result[unit, string] {
    if !key_imported(id)? { return Ok(()) }
    let version = id.split("-")[0]
    let cmd = "if rpmkeys --help 2>/dev/null | grep -q -- --delete; then rpmkeys --delete " + q(version) + "; else rpm -e --allmatches " + q("gpg-pubkey-" + id) + "; fi"
    run("removing key " + id, cmd)
}
