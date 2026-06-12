use value
use fs

fn has_any(a: string, b: string) -> bool {
    fs::exists(a) || fs::exists(b)
}

fn gather(params: Value) -> Value {
    let has6 = has_any("/usr/bin/kreadconfig6", "/bin/kreadconfig6") || has_any("/usr/bin/kwriteconfig6", "/bin/kwriteconfig6")
    let has5 = has_any("/usr/bin/kreadconfig5", "/bin/kreadconfig5") || has_any("/usr/bin/kwriteconfig5", "/bin/kwriteconfig5")
    let major = if has6 { 6 } else if has5 { 5 } else { 0 }
    Value::Map(#{
        "plasma_major": Value::Int(major),
        "has_kreadconfig6": Value::Bool(has6),
        "has_legacy_kconfig_tools": Value::Bool(has5)
    })
}

