use value
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
