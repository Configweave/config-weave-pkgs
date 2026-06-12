use value
use env

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn home(params: Value) -> string {
    let h = param_str(params, "home", "")
    if h != "" { h } else { env::home_dir() }
}

fn gather(params: Value) -> Value {
    let h = home(params)
    Value::Map(#{
        "home": Value::String(h),
        "config": Value::String(h + "/.tmux.conf"),
        "tmuxinator_dir": Value::String(h + "/.config/tmuxinator"),
        "teamocil_dir": Value::String(h + "/.teamocil")
    })
}

