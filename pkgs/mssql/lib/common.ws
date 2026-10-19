use value
use fs
use shell
use sys
use registry
use service
use time
use http
use hash
use json
use path
use log

// Shared helpers for the mssql package: parameter access, quoting for the
// shells and for T-SQL, and the sqlcmd runner every T-SQL resource uses.

// --- parameters ---------------------------------------------------------------

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

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn require(params: Value, key: string) -> Result[string, string] {
    let v = param_str(params, key, "")
    if v == "" { return Err("missing '" + key + "' parameter") }
    Ok(v)
}

fn csv(s: string) -> List[string] {
    let out = []
    for part in s.split(",") {
        let t = part.trim()
        if t != "" { out.push(t) }
    }
    out
}

// --- quoting ------------------------------------------------------------------

// POSIX single quoting. Valid for `shell::bash` and for `shell::run`, whose
// shell-words splitter follows the same rules on every platform.
fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

// PowerShell single-quoted literal. PowerShell also treats the curly single
// quotes U+2018 to U+201B as quote characters, so they are doubled too.
fn ps_q(s: string) -> string {
    "'" + s.replace("'", "''").replace("‘", "‘‘").replace("’", "’’").replace("‚", "‚‚").replace("‛", "‛‛") + "'"
}

// T-SQL Unicode string literal and bracket-quoted identifier.
fn tsql_lit(s: string) -> string { "N'" + s.replace("'", "''") + "'" }
fn tsql_id(s: string) -> string { "[" + s.replace("]", "]]") + "]" }
fn tsql_bool(b: bool) -> string { if b { "1" } else { "0" } }

// --- validation ---------------------------------------------------------------

fn only_chars(s: string, extra: string) -> bool {
    for c in s.chars() {
        let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || extra.contains(str(c))
        if !ok { return false }
    }
    true
}

// A collation name is spliced into T-SQL and mssql-conf as a bare word.
fn check_collation(c: string) -> Result[unit, string] {
    if c != "" && !only_chars(c, "_") {
        return Err("invalid collation '" + c + "' (letters, digits and _ only)")
    }
    Ok(())
}

// An instance name becomes part of a registry path, a service name and a
// PowerShell argument.
fn check_instance(name: string) -> Result[unit, string] {
    if name != "" && !only_chars(name, "_$") {
        return Err("invalid instance name '" + name + "' (letters, digits, _ and $ only)")
    }
    Ok(())
}

fn no_newlines(key: string, v: string) -> Result[unit, string] {
    if v.contains("\n") || v.contains("\r") { return Err("'" + key + "' must not contain a line break") }
    Ok(())
}

// --- errors -------------------------------------------------------------------

// The useful text of a failed command: stderr, else stdout, plus the code.
fn cmd_error(what: string, out: CmdOutput) -> string {
    let detail = if out.stderr.trim() != "" { out.stderr.trim() } else { out.stdout.trim() }
    what + " failed (exit " + str(out.code) + "): " + detail
}

// --- sqlcmd -------------------------------------------------------------------

fn sqlcmd_bin() -> string {
    if sys::family() == "windows" {
        if fs::exists("C:\\Program Files\\sqlcmd\\sqlcmd.exe") { return "C:\\Program Files\\sqlcmd\\sqlcmd.exe" }
        for v in ["170", "160", "150", "130"] {
            let p = "C:\\Program Files\\Microsoft SQL Server\\Client SDK\\ODBC\\" + v + "\\Tools\\Binn\\SQLCMD.EXE"
            if fs::exists(p) { return p }
        }
        return "sqlcmd"
    }
    if fs::exists("/opt/mssql-tools18/bin/sqlcmd") { return "/opt/mssql-tools18/bin/sqlcmd" }
    if fs::exists("/opt/mssql-tools/bin/sqlcmd") { return "/opt/mssql-tools/bin/sqlcmd" }
    "sqlcmd"
}

fn sqlcmd_target(params: Value) -> string {
    let server = param_str(params, "server", "")
    let inst = param_str(params, "instance", "")
    let base = if server != "" { server } else if sys::family() == "windows" { "(local)" } else { "localhost" }
    if inst != "" && inst != "MSSQLSERVER" { base + "\\" + inst } else { base }
}

// Runs a T-SQL batch. The batch goes to sqlcmd on stdin and the SQL password
// through SQLCMDPASSWORD, so neither reaches the command line or the disk.
fn sqlcmd(params: Value, batch: string, scalar: bool) -> Result[string, string] {
    let user = param_str(params, "sql_user", "")
    let pw = param_str(params, "sql_password", "")
    let trust = if param_bool(params, "trust_server_certificate", true) { " -C" } else { "" }
    let fmt_args = if scalar { " -h -1 -W" } else { "" }
    let cmd = q(sqlcmd_bin()) + " -S " + q(sqlcmd_target(params)) + trust + " -l 30 -b -r 1" + fmt_args
    let stdin = Value::String("SET NOCOUNT ON;\n" + batch + "\n")
    let out = if user != "" {
        // sqlcmd prompts for a password it was not given, and would read the
        // batch from stdin as that password.
        if pw == "" { return Err("'sql_password' is required when 'sql_user' is set") }
        shell::run(cmd + " -U " + q(user), Value::Map(#{
            "stdin": stdin,
            "env": Value::Map(#{ "SQLCMDPASSWORD": Value::String(pw) })
        }))?
    } else {
        shell::run(cmd + " -E", Value::Map(#{ "stdin": stdin }))?
    }
    if !out.success { return Err(cmd_error("sqlcmd", out)) }
    Ok(out.stdout)
}

fn run_scalar(params: Value, query: string) -> Result[string, string] {
    let out = sqlcmd(params, query, true)?
    Ok(out.trim())
}

fn run_exec(params: Value, batch: string) -> Result[unit, string] {
    sqlcmd(params, batch, false)?
    Ok(())
}

// Compares an object's properties server-side. `from_where` selects at most
// one row; each check is [name, condition]. Returns None when there is no row,
// otherwise the names of the checks whose condition is not true (a NULL
// comparison counts as drift).
fn drift(params: Value, from_where: string, checks: List[List[string]]) -> Result[Option[List[string]], string] {
    drift_in(params, "", from_where, checks)
}

// drift() run in the context of database `db` ("" = the login's default).
fn drift_in(params: Value, db: string, from_where: string, checks: List[List[string]]) -> Result[Option[List[string]], string] {
    let parts = checks.map(|c| "CASE WHEN " + c[1] + " THEN N'' ELSE N' " + c[0] + "' END")
    let sel = if parts.is_empty() { "N'ROW'" } else { "CONCAT(N'ROW', " + parts.join(", ") + ")" }
    let use_db = if db != "" { "USE " + tsql_id(db) + "; " } else { "" }
    let r = run_scalar(params, use_db + "SELECT TOP (1) " + sel + " " + from_where + ";")?
    if r == "" { return Ok(None) }
    let names = []
    for w in r.split(" ") {
        if w != "" && w != "ROW" { names.push(w) }
    }
    Ok(Some(names))
}

// --- Windows service plumbing --------------------------------------------------

fn win_service_name(inst: string) -> string {
    if inst == "" || inst == "MSSQLSERVER" { "MSSQLSERVER" } else { "MSSQL$" + inst }
}

fn win_agent_name(inst: string) -> string {
    if inst == "" || inst == "MSSQLSERVER" { "SQLSERVERAGENT" } else { "SQLAgent$" + inst }
}

// The instance id (e.g. MSSQL16.MSSQLSERVER) that names its registry hive,
// or "" when the instance is not installed.
fn win_instance_id(inst: string) -> Result[string, string] {
    win_component_id("SQL", inst)
}

// The id of one component of an instance, from the key setup registers it
// under: Instance Names\SQL for the engine (MSSQL15.X), OLAP for Analysis
// Services (MSAS15.X) and RS for Reporting Services (MSRS13.X, or SSRS for
// the 2017+ standalone server). "" when that component is not installed.
fn win_component_id(kind: string, inst: string) -> Result[string, string] {
    check_instance(inst)?
    let name = if inst == "" { "MSSQLSERVER" } else { inst }
    let key = "HKLM\\SOFTWARE\\Microsoft\\Microsoft SQL Server\\Instance Names\\" + kind
    if let Some(v) = registry::read(key, name)? {
        if let Some(s) = v.as_string() { return Ok(s) }
    }
    Ok("")
}

// Restarts the engine and waits for it. The SCM will not stop a service
// whose dependents are running (SQL Server Agent depends on the engine), so
// the running dependents are stopped first and started again afterwards.
// The host service API cannot list dependents; PowerShell only reads their
// names, in the order EnumDependentServices gives (safe to stop in).
fn win_restart_engine(inst: string) -> Result[unit, string] {
    check_instance(inst)?
    let engine = win_service_name(inst)
    let opts = Value::Map(#{ "timeout": Value::Int(300) })
    let script = "$ErrorActionPreference = 'Stop'; " +
        "(Get-Service -Name " + ps_q(engine) + ").DependentServices | " +
        "Where-Object {{ $_.Status -eq 'Running' }} | ForEach-Object {{ $_.Name }}"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(cmd_error("listing the services that depend on " + engine, out)) }
    let dependents: List[string] = []
    for line in out.stdout.split("\n") {
        let n = line.trim()
        if n != "" { dependents.push(n) }
    }
    for d in dependents { service::stop_with(d, opts)? }
    service::restart(engine, opts)?
    let i = dependents.len() - 1
    while i >= 0 {
        service::start_with(dependents.get(i).unwrap_or(""), opts)?
        i = i - 1
    }
    Ok(())
}

// Polls until the engine accepts a connection, for up to `secs` seconds.
fn wait_for_engine(params: Value, secs: int) -> Result[unit, string] {
    let start = time::instant()
    let last = ""
    loop {
        match run_scalar(params, "SELECT 1;") {
            Ok(_) => return Ok(()),
            Err(e) => last = e
        }
        if time::elapsed(start) > float(secs) { return Err("SQL Server did not accept connections within " + str(secs) + "s: " + last) }
        time::sleep(2000)
    }
}

// --- PowerShell -----------------------------------------------------------------

// Windows PowerShell 5.1 writes stdout in the OEM code page unless told
// otherwise, which mangles non-ASCII names; the wrapper reduces a terminating
// error to its message rather than the echoed source line.
fn ps_preamble() -> string {
    "$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\n" +
        "try {{ [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }} catch {{ }}\n"
}

// Runs `script` with `env` (secrets travel here, read as $env:NAME) and
// returns its trimmed stdout. `timeout` 0 = the host default.
fn ps_env(what: string, script: string, env: Map[string, Value], timeout: int) -> Result[string, string] {
    let opts = #{}
    if env.len() > 0 { opts.insert("env", Value::Map(env)) }
    if timeout > 0 { opts.insert("timeout", Value::Int(timeout)) }
    let body = ps_preamble() + "try {{\n" + script + "\nexit 0\n}} catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}"
    let out = shell::powershell(body, Value::Map(opts))?
    if !out.success { return Err(cmd_error(what, out)) }
    Ok(out.stdout.trim())
}

fn ps(what: string, script: string) -> Result[string, string] { ps_env(what, script, #{}, 0) }

// A script whose stdout is one JSON document.
fn ps_json(what: string, script: string, env: Map[string, Value]) -> Result[Value, string] {
    let text = ps_env(what, script, env, 0)?
    if text == "" { return Err(what + " printed nothing") }
    match json::parse(text) {
        Ok(v) => Ok(v),
        Err(e) => Err(what + " printed something that is not JSON (" + e + "): " + text)
    }
}

// --- downloads ----------------------------------------------------------------

// Downloads `url` to `dest`. http::download can leave a partial file behind
// and does not retry (config-weave#11), so the file goes to a temp name
// beside `dest`, its size is checked against the byte count and its sha256
// against `sha256` when one is given, a failed attempt is retried up to three
// times, and only a verified file is renamed into place.
fn download_verified(url: string, dest: string, sha256: string) -> Result[unit, string] {
    let want = sha256.trim().to_lower()
    let tmp = dest + ".config-weave-" + str(time::now_millis()) + ".part"
    let last = ""
    let attempt = 1
    while attempt <= 3 {
        log::info("downloading " + url + " (attempt " + str(attempt) + ")")
        match http::download(url, tmp, Value::Null) {
            Ok(n) => {
                let size = if let Ok(m) = fs::metadata(tmp) { if let Some(l) = m.get("size") { l.as_int().unwrap_or(-1) } else { -1 } } else { -1 }
                if size != n {
                    last = "got " + str(size) + " bytes on disk, expected " + str(n)
                } else if want != "" && hash::sha256_file(tmp)?.to_lower() != want {
                    last = "sha256 mismatch: expected " + want + ", got " + hash::sha256_file(tmp)?
                } else {
                    if fs::exists(dest) { fs::delete(dest)? }
                    fs::move(tmp, dest)?
                    return Ok(())
                }
            }
            Err(e) => last = e
        }
        fs::delete(tmp).unwrap_or(())
        attempt = attempt + 1
        if attempt <= 3 { time::sleep(3000) }
    }
    Err("downloading " + url + " failed after 3 attempts: " + last)
}

// A local copy of an installer that may be given as a URL. Returns the path
// and whether it is a temporary download the caller deletes.
fn local_installer(src: string, name: string, sha256: string) -> Result[List[string], string] {
    if src.starts_with("http://") || src.starts_with("https://") {
        let dir = fs::temp_dir()?
        let f = path::join(dir, name)
        if let Err(e) = download_verified(src, f, sha256) {
            fs::delete_dir(dir).unwrap_or(())
            return Err(e)
        }
        return Ok([f, dir])
    }
    if !fs::exists(src) { return Err("installer '" + src + "' does not exist") }
    if sha256 != "" && hash::sha256_file(src)?.to_lower() != sha256.trim().to_lower() {
        return Err("installer '" + src + "' does not match its sha256")
    }
    Ok([src, ""])
}
