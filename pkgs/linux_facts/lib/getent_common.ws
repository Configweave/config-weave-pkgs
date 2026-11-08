use value
use shell

// The getent gatherer's lookup, kept apart from common.ws. The verify
// script of getent_errors calls lookup() directly, because a gatherer that
// returns Err fails a test before any verify could look at the message.

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

// Only the three non-secret databases: never shadow or gshadow.
fn check_database(db: string) -> Result[unit, string] {
    if db == "passwd" || db == "group" || db == "hosts" { return Ok(()) }
    Err("invalid database '" + db + "' (expected :passwd, :group or :hosts)")
}

// The key reaches getent as one operand after "--". A NUL or a line break
// cannot be passed or would split the output into records, and a leading
// "-" reads as an option to anything that ignores "--".
fn check_key(key: string) -> Result[unit, string] {
    if key.contains("\u{0}") { return Err("'key' must not contain a NUL byte") }
    if key.contains("\n") || key.contains("\r") { return Err("'key' must not contain line breaks") }
    if key.starts_with("-") { return Err("'key' must not start with '-': '" + key + "'") }
    Ok(())
}

// One output line as its columns. passwd (7) and group (4) split on ":"
// and keep empty columns; hosts splits on whitespace and keeps every alias.
fn split_record(db: string, line: string) -> Result[List[string], string] {
    if db == "hosts" {
        let f = []
        for p in line.replace("\t", " ").split(" ") {
            if p != "" { f.push(p) }
        }
        if f.len() < 2 { return Err("malformed hosts record from getent: '" + line + "'") }
        return Ok(f)
    }
    let want = if db == "passwd" { 7 } else { 4 }
    let f = line.split(":")
    if f.len() != want {
        return Err("malformed " + db + " record from getent (" + str(f.len()) + " fields, expected " + str(want) + "): '" + line + "'")
    }
    Ok(f)
}

fn result(db: string, key: string, entries: List[Value]) -> Value {
    Value::Map(#{
        "database": Value::String(db),
        "key": Value::String(key),
        "found": Value::Bool(!entries.is_empty()),
        "count": Value::Int(entries.len()),
        "entries": Value::List(entries)
    })
}

fn cmd_err(cmd: string, out: CmdOutput) -> string {
    let text = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    let head = cmd + " failed (exit " + str(out.code) + ")"
    if text == "" { head } else { head + ": " + text }
}

// getent exit codes: 0 records follow, 1 bad arguments or unknown
// database, 2 a key was not found, 3 enumeration is not supported. Only
// exit 2 of a keyed lookup is an empty result. Everything else that is not
// exit 0, a getent that cannot be started included, is an error, so a
// broken lookup never reads as an empty database.
fn lookup(db: string, key: string) -> Result[Value, string] {
    check_database(db)?
    check_key(key)?
    let cmd = if key == "" { "getent -- " + q(db) } else { "getent -- " + q(db) + " " + q(key) }
    let shown = if key == "" { "getent " + db } else { "getent " + db + " " + q(key) }
    let ran = shell::run(cmd, Value::Map(#{ "timeout": Value::Int(120) }))
    if let Err(e) = ran { return Err("cannot run getent (libc-bin provides it): " + e) }
    let out = ran.unwrap()
    if out.code == 2 && key != "" { return Ok(result(db, key, [])) }
    if !out.success { return Err(cmd_err(shown, out)) }

    let entries = []
    for line in out.stdout.split("\n") {
        if line == "" { continue }
        let fields = []
        for f in split_record(db, line)? { fields.push(Value::String(f)) }
        entries.push(Value::Map(#{ "fields": Value::List(fields) }))
    }
    if key != "" && entries.is_empty() { return Err(shown + " exited 0 but printed no record") }
    Ok(result(db, key, entries))
}
