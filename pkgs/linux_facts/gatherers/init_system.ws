use value
use fs
use shell

fn command_success(cmd: string) -> bool {
    let out = shell::run(cmd, Value::Null).unwrap_or(CmdOutput { stdout: "", stderr: "", code: 127, success: false })
    out.success
}

// The bare token, without a leading colon: `:systemd` is a WCL *source*
// spelling, and the engine promotes a symbol-typed `returns` key into a real
// WCL symbol on the way into the variable space.
fn gather(params: Value) -> Value {
    let init = if fs::exists("/run/systemd/system") && command_success("systemctl --version") {
        "systemd"
    } else if fs::exists("/sbin/openrc") || fs::exists("/run/openrc") {
        "openrc"
    } else if fs::exists("/run/runit") || fs::exists("/etc/runit") {
        "runit"
    } else if command_success("service --version") {
        "sysvinit"
    } else {
        "unknown"
    }
    Value::Map(#{
        "init": Value::String(init)
    })
}

