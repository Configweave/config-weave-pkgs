use value
use fs
use shell

// Helpers shared by linux_facts' gatherers. Imported with `use common`;
// nothing here is package-external.

// Whitespace-separated fields, runs of spaces collapsed.
fn fields(line: string) -> List[string] {
    let f = []
    for p in line.split(" ") {
        if p != "" { f.push(p) }
    }
    f
}

// stdout of a best-effort command, trimmed; "" when it fails or is missing.
fn run_stdout(cmd: string) -> string {
    let out = shell::bash(cmd, Value::Null).unwrap_or(CmdOutput { stdout: "", stderr: "", code: 127, success: false })
    if out.success { out.stdout.trim() } else { "" }
}

fn run_ok(cmd: string) -> bool {
    let out = shell::bash(cmd, Value::Null).unwrap_or(CmdOutput { stdout: "", stderr: "", code: 127, success: false })
    out.success
}

// /proc/mounts escapes a space, tab, newline or backslash in a field as
// octal \NNN; the kernel escapes exactly these. Backslash goes last so an
// escaped backslash is never re-read as the start of another escape.
fn unescape_octal(f: string) -> string {
    f.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")
}

// Whether a process with this /proc/<pid>/comm is running. Works under
// any init system, unlike `systemctl is-active`. comm is truncated to 15
// characters, so pass names as the kernel stores them.
fn process_running(comm: string) -> bool {
    for p in fs::glob("/proc/[0-9]*/comm").unwrap_or([]) {
        if fs::read(p).unwrap_or("").trim() == comm { return true }
    }
    false
}
