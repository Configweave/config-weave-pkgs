use value
use fs
use shell

// Service lists for hosts without a reachable systemd: OpenRC, runit and
// SysV. Each backend reads state the way the linux_openrc, linux_runit and
// linux_sysvinit service resources do. Imported by gatherers/services.ws
// with `use services_backend`.
//
// Every entry has the systemd shape { name, active, sub, enabled }:
// - active uses systemd's words (active, inactive, failed, activating,
//   deactivating), so `active == "active"` means running under any manager.
// - sub is the manager's own state word (started, run, running, ...).
// - enabled is "enabled" or "disabled", by the manager's own boot rule.
// A service whose state command errors is left out; it is no service, not
// a failed gather.

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn sh(cmd: string) -> CmdOutput {
    shell::bash(cmd, Value::Map(#{ "timeout": Value::Int(15) })).unwrap_or(CmdOutput { stdout: "", stderr: "", code: 127, success: false })
}

fn has_cmd(name: string) -> bool { sh("command -v " + name + " >/dev/null 2>&1").success }

// A name taken from a directory listing that is safe as a path part, a
// glob part and a command operand: the rule of the resources' require_name.
fn plain(name: string) -> bool {
    if name == "" || name.starts_with(".") || name.starts_with("-") { return false }
    for c in ["/", "\\", "*", "?", "[", "]", " ", "\t", "\n", "\r", "'"] {
        if name.contains(c) { return false }
    }
    true
}

fn entry(name: string, active: string, sub: string, enabled: string) -> Value {
    Value::Map(#{
        "name": Value::String(name),
        "active": Value::String(active),
        "sub": Value::String(sub),
        "enabled": Value::String(enabled)
    })
}

// Each *_state function maps a manager state to [active, sub], or to []
// for an unknown state: that service is then left out.

// ---- OpenRC ----

// Its runtime state exists (/run/openrc, what a booted OpenRC or a marked
// softlevel leaves) and its tools answer.
fn openrc_present() -> bool {
    fs::is_dir("/run/openrc") && has_cmd("rc-service") && sh("rc-status --list >/dev/null 2>&1").success
}

// Runlevel membership is a symlink /etc/runlevels/<runlevel>/<name>, in
// any runlevel (boot, sysinit, default, custom).
fn openrc_enabled(name: string) -> bool {
    for l in fs::glob("/etc/runlevels/*/" + name).unwrap_or([]) {
        if fs::read_link(l).is_ok() { return true }
    }
    false
}

// `rc-service <name> status` exit codes: 0 started, 3 stopped,
// 4 stopping, 8 starting, 16 inactive, 32 crashed.
fn openrc_state(code: int) -> List[string] {
    if code == 0 { return ["active", "started"] }
    if code == 3 { return ["inactive", "stopped"] }
    if code == 4 { return ["deactivating", "stopping"] }
    if code == 8 { return ["activating", "starting"] }
    if code == 16 { return ["inactive", "inactive"] }
    if code == 32 { return ["failed", "crashed"] }
    []
}

fn openrc_services() -> List[Value] {
    let out = []
    let names = []
    for line in sh("rc-service --list 2>/dev/null").stdout.split("\n") {
        let n = line.trim()
        if plain(n) { names.push(n) }
    }
    names.sort()
    for n in names {
        let code = sh("rc-service " + q(n) + " status >/dev/null 2>&1").code
        let en = if openrc_enabled(n) { "enabled" } else { "disabled" }
        let st = openrc_state(code)
        if st.len() == 2 { out.push(entry(n, st.get(0).unwrap_or(""), st.get(1).unwrap_or(""), en)) }
    }
    out
}

// ---- runit ----

// Where runsvdir watches for service links: Alpine and Void, Debian,
// the old default, Artix.
fn runit_service_dirs() -> List[string] { ["/var/service", "/etc/service", "/service", "/run/runit/service"] }

// Where service definitions (a directory with a `run` script) live.
fn runit_sv_dirs() -> List[string] { ["/etc/sv", "/etc/runit/sv"] }

// The first service dir in which runsv supervises at least one entry:
// `sv status` fails on a directory that nothing supervises. "" for none.
fn runit_service_dir() -> string {
    if !has_cmd("sv") { return "" }
    for d in runit_service_dirs() {
        if !fs::is_dir(d) { continue }
        for n in fs::list_dir(d).unwrap_or([]) {
            if plain(n) && sh("sv status " + q(d + "/" + n) + " >/dev/null 2>&1").success { return d }
        }
    }
    ""
}

// Status lines look like "run: /var/service/x: (pid 813) 5s[, normally
// down][; run: log: ...]". The word before the first ':' is the state.
fn runit_state(word: string) -> List[string] {
    if word == "run" { return ["active", "run"] }
    if word == "down" { return ["inactive", "down"] }
    if word == "finish" { return ["deactivating", "finish"] }
    []
}

fn runit_services(dir: string) -> List[Value] {
    let out = []
    let seen: Map[string, bool] = #{}
    // Linked into the service dir: enabled. A link that runsv does not
    // supervise (yet) has no status and is left out.
    for n in fs::list_dir(dir).unwrap_or([]) {
        if !plain(n) { continue }
        seen.insert(n, true)
        let res = sh("sv status " + q(dir + "/" + n) + " 2>/dev/null")
        if !res.success { continue }
        let word = res.stdout.trim().split(":").get(0).unwrap_or("")
        let st = runit_state(word)
        if st.len() == 2 { out.push(entry(n, st.get(0).unwrap_or(""), st.get(1).unwrap_or(""), "enabled")) }
    }
    // Defined but not linked: disabled, and nothing supervises it, so down.
    let names = []
    for svd in runit_sv_dirs() {
        for n in fs::list_dir(svd).unwrap_or([]) {
            if !plain(n) || seen.contains_key(n) { continue }
            if !fs::is_file(svd + "/" + n + "/run") { continue }
            seen.insert(n, true)
            names.push(n)
        }
    }
    names.sort()
    for n in names { out.push(entry(n, "inactive", "down", "disabled")) }
    out
}

// ---- SysV ----

// Not scripts that run a service.
fn sysv_skip(name: string) -> bool {
    name == "README" || name == "skeleton" || name == "functions" || name == "rc" || name == "rcS" || name.contains(".dpkg-")
}

fn sysv_names() -> List[string] {
    let names = []
    for n in fs::list_dir("/etc/init.d").unwrap_or([]) {
        if plain(n) && !sysv_skip(n) { names.push(n) }
    }
    names
}

fn sysv_present() -> bool { !sysv_names().is_empty() && has_cmd("service") }

// Enabled means a start link in some runlevel directory, as the resource
// reads it. A disabled service may still have kill links.
fn sysv_enabled(name: string) -> bool { !fs::glob("/etc/rc?.d/S??" + name).unwrap_or([]).is_empty() }

// The script's own `status` verb, with LSB exit codes: 0 running, 1 dead
// with a pid file, 2 dead with a lock file, 3 not running. Any other code
// (4 unknown, a missing verb that exits otherwise) and a file that is not
// an executable script leave the service out.
fn sysv_state(code: int) -> List[string] {
    if code == 0 { return ["active", "running"] }
    if code == 1 || code == 2 { return ["failed", "dead"] }
    if code == 3 { return ["inactive", "stopped"] }
    []
}

fn sysv_services() -> List[Value] {
    let out = []
    for n in sysv_names() {
        let p = q("/etc/init.d/" + n)
        let code = sh("[ -f " + p + " ] && [ -x " + p + " ] || exit 200; " + p + " status </dev/null >/dev/null 2>&1").code
        let en = if sysv_enabled(n) { "enabled" } else { "disabled" }
        let st = sysv_state(code)
        if st.len() == 2 { out.push(entry(n, st.get(0).unwrap_or(""), st.get(1).unwrap_or(""), en)) }
    }
    out
}

// The services of the first manager present, in the order OpenRC, runit,
// SysV; [] with none. init_system is not used: in a container PID 1 is an
// entrypoint, yet these managers still run services there.
fn services() -> List[Value] {
    if openrc_present() { return openrc_services() }
    let rdir = runit_service_dir()
    if rdir != "" { return runit_services(rdir) }
    if sysv_present() { return sysv_services() }
    let none: List[Value] = []
    none
}
