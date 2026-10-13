use value
use common
use shell

// Major version of the installed Plasma shell, from `plasmashell --version`
// ("plasmashell 6.1.5"); 0 when plasmashell is missing or prints nothing
// usable. The minimal Qt platform lets it answer without a display (the
// default and offscreen platforms crash on --version without one).
fn plasma_major() -> int {
    if !common::on_path("plasmashell") { return 0 }
    let out = shell::bash("QT_QPA_PLATFORM=minimal timeout 10 plasmashell --version 2>/dev/null", Value::Null)
    if let Ok(o) = out {
        let words = o.stdout.trim().split(" ")
        if let Some(last) = words.last() {
            if let Some(n) = last.split(".").get(0).unwrap_or("").parse_int() { return n }
        }
    }
    0
}

fn gather(params: Value) -> Value {
    let has6 = common::on_path("kreadconfig6") || common::on_path("kwriteconfig6")
    let has5 = common::on_path("kreadconfig5") || common::on_path("kwriteconfig5")
    let tools = if has6 { 6 } else if has5 { 5 } else { 0 }
    Value::Map(#{
        "plasma_major": Value::Int(plasma_major()),
        "kconfig_tools_major": Value::Int(tools),
        "has_kreadconfig6": Value::Bool(has6),
        "has_legacy_kconfig_tools": Value::Bool(has5 && !has6)
    })
}
