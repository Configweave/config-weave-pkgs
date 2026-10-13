use value
use common

fn gather(params: Value) -> Value {
    let h = common::home(params)
    Value::Map(#{
        "home": Value::String(h),
        "config_dir": Value::String(h + "/.config"),
        "local_share_dir": Value::String(h + "/.local/share"),
        "has_kreadconfig6": Value::Bool(common::on_path("kreadconfig6")),
        "has_kwriteconfig6": Value::Bool(common::on_path("kwriteconfig6")),
        "has_plasma_apply_colorscheme": Value::Bool(common::on_path("plasma-apply-colorscheme"))
    })
}
