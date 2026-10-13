use value
use common
use fs

fn gather(params: Value) -> Value {
    let h = common::home(params)
    Value::Map(#{
        "home": Value::String(h),
        "config_dir": Value::String(h + "/.config"),
        "local_share_dir": Value::String(h + "/.local/share"),
        "has_kreadconfig6": Value::Bool(common::has_any("/usr/bin/kreadconfig6", "/bin/kreadconfig6")),
        "has_kwriteconfig6": Value::Bool(common::has_any("/usr/bin/kwriteconfig6", "/bin/kwriteconfig6")),
        "has_plasma_apply_colorscheme": Value::Bool(common::has_any("/usr/bin/plasma-apply-colorscheme", "/bin/plasma-apply-colorscheme"))
    })
}

