use value
use env
use shell

fn run_stdout(cmd: string) -> string {
    let out = shell::bash(cmd, Value::Null).unwrap_or(CmdOutput { stdout: "", stderr: "", code: 127, success: false })
    if out.success { out.stdout.trim() } else { "" }
}

fn gather(params: Value) -> Value {
    Value::Map(#{
        "hostname": Value::String(env::hostname()),
        "default_ipv4": Value::String(run_stdout("hostname -I 2>/dev/null | awk '{print $1}'")),
        "fqdn": Value::String(run_stdout("hostname -f 2>/dev/null"))
    })
}

