use value
use shell

fn gather(params: Value) -> Value {
    let out = shell::run("tmux -V", Value::Null).unwrap_or(CmdOutput { stdout: "", stderr: "", code: 127, success: false })
    Value::Map(#{
        "installed": Value::Bool(out.success),
        "version": Value::String(out.stdout.trim())
    })
}

