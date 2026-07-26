use value
use fs
use shell

fn command_success(cmd: string) -> bool {
    let out = shell::run(cmd, Value::Null).unwrap_or(CmdOutput { stdout: "", stderr: "", code: 127, success: false })
    out.success
}

fn gather(params: Value) -> Value {
    let init = if fs::exists("/run/systemd/system") && command_success("systemctl --version") {
        "systemd"
    } else if fs::exists("/sbin/openrc") || fs::exists("/run/openrc") {
        "openrc"
    } else if command_success("service --version") {
        "sysv"
    } else {
        "unknown"
    }
    Value::Map(#{
        "init": Value::String(init)
    })
}

