use value
use env
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn home(params: Value) -> string {
    let h = param_str(params, "home", "")
    if h != "" { h } else { env::home_dir() }
}

fn has_any(a: string, b: string) -> bool {
    fs::exists(a) || fs::exists(b)
}

fn gather(params: Value) -> Value {
    let h = home(params)
    Value::Map(#{
        "home": Value::String(h),
        "config_dir": Value::String(h + "/.config"),
        "local_share_dir": Value::String(h + "/.local/share"),
        "has_kreadconfig6": Value::Bool(has_any("/usr/bin/kreadconfig6", "/bin/kreadconfig6")),
        "has_kwriteconfig6": Value::Bool(has_any("/usr/bin/kwriteconfig6", "/bin/kwriteconfig6")),
        "has_plasma_apply_colorscheme": Value::Bool(has_any("/usr/bin/plasma-apply-colorscheme", "/bin/plasma-apply-colorscheme"))
    })
}

