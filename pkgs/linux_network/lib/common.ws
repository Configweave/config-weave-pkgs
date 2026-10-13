use value
use fs
use shell

// Helpers shared by linux_network's resources. Imported with `use common`;
// nothing here is package-external.

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// A failed command's error: stderr, else stdout (ufw and firewall-cmd
// report some failures there), always with the exit code.
fn cmd_err(what: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = what + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

fn run(what: string, cmd: string) -> Result[CmdOutput, string] {
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(out)
}

// Values that reach a command line or a line-based file stay on one line.
fn one_line(key: string, v: string) -> Result[unit, string] {
    if v.contains("\n") || v.contains("\r") { return Err("'" + key + "' must not contain line breaks") }
    Ok(())
}

fn has_space(v: string) -> bool { v.contains(" ") || v.contains("\t") }

// A single token: non-empty, no whitespace or line breaks.
fn token(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    one_line(key, v)?
    if has_space(v) { return Err("'" + key + "' must not contain whitespace") }
    Ok(())
}

fn require_nft() -> Result[unit, string] {
    if fs::exists("/usr/sbin/nft") || fs::exists("/usr/bin/nft") || fs::exists("/sbin/nft") { return Ok(()) }
    Err("nft not found; is nftables installed?")
}

// nftables table and chain names: an identifier nft accepts unquoted, so it
// can go into an `nft -f` script as is.
fn nft_name(key: string, v: string) -> Result[unit, string] {
    if v == "" { return Err("missing '" + key + "' parameter") }
    let first = true
    for c in v.chars() {
        let alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        let ok = if first { alpha || c == '_' } else { alpha || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' }
        if !ok { return Err("'" + key + "' must start with a letter or '_' and contain only letters, digits, '_', '-' and '.' (got '" + v + "')") }
        first = false
    }
    Ok(())
}

fn nft_family(params: Value) -> Result[string, string] {
    let f = param_str(params, "family", "inet")
    if f == "inet" || f == "ip" || f == "ip6" || f == "arp" || f == "bridge" || f == "netdev" { return Ok(f) }
    Err("invalid 'family' value '" + f + "' (expected :inet, :ip, :ip6, :arp, :bridge or :netdev)")
}

// Run an nft script through `nft -f -`: one transaction, and nothing in it
// passes through a shell.
fn nft_script(what: string, script: string, flags: string) -> Result[CmdOutput, string] {
    let out = shell::bash("nft " + flags + " -f -", Value::Map(#{ "stdin": Value::String(script + "\n") }))?
    if !out.success { return Err(cmd_err(what, out)) }
    Ok(out)
}

// A table or chain reference for nft: the family, then each name. nft
// (1.0.9 at least) does not accept quoted names here, so a name that is
// also an nft keyword (fwd, counter, ...) fails with nft's syntax error.
fn nft_ref(family: string, names: List[string]) -> string {
    let out = family
    for n in names { out = out + " " + n }
    out
}

// `nft <flags> list <what> <ref>`: None when it does not exist, an error
// for any other failure (no permission, no nf_tables in the kernel). nft
// joins its arguments into one command, so the whole command is one
// shell-quoted word.
fn nft_list(flags: string, what: string) -> Result[Option[string], string] {
    let out = shell::bash("nft " + flags + " " + q("list " + what), Value::Null)?
    if out.success { return Ok(Some(out.stdout)) }
    if out.stderr.contains("No such file or directory") { return Ok(None) }
    Err(cmd_err("nft list " + what, out))
}
