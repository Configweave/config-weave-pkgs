use value
use registry

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

// The Automatic Updates policy key. NoAutoUpdate = 1 disables automatic
// download/install; 0 (or absent) leaves automatic updates on.
fn au_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" }

// Current NoAutoUpdate value (absent = 0 = automatic updates enabled).
fn no_auto_update() -> Result[int, string] {
    if let Some(v) = registry::read(au_key(), "NoAutoUpdate")? {
        return Ok(v.as_int().unwrap_or(0))
    }
    Ok(0)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let want = if param_bool(params, "enabled", true) { 0 } else { 1 }
    if no_auto_update()? == want { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let want = if param_bool(params, "enabled", true) { 0 } else { 1 }
    registry::create_key(au_key())?
    registry::write(au_key(), "NoAutoUpdate", Value::Int(want), "dword")?
    Ok(ApplyResult::Success)
}
