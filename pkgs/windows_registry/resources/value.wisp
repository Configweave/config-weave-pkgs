use value
use registry
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) {
        if let Some(s) = v.as_string() { return s }
    }
    fallback
}

fn desired(data: string, kind: string) -> Result[Value, string] {
    if kind == "dword" || kind == "qword" {
        if let Some(i) = data.parse_int() {
            Ok(Value::Int(i))
        } else {
            Err("data '" + data + "' is not a number (required for " + kind + ")")
        }
    } else if kind == "sz" || kind == "expand_sz" {
        Ok(Value::String(data))
    } else {
        Err("unsupported kind '" + kind + "' (use sz, expand_sz, dword or qword)")
    }
}

fn matches(have: Value, want: Value) -> bool {
    if let Some(s) = want.as_string() {
        if let Some(hs) = have.as_string() { return hs == s }
    }
    if let Some(i) = want.as_int() {
        if let Some(hi) = have.as_int() { return hi == i }
    }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let key = param_str(params, "key", "")
    let name = param_str(params, "name", "")
    if key == "" || name == "" { return Err("missing 'key' or 'name' parameter") }
    let want = desired(param_str(params, "data", ""), param_str(params, "kind", "sz"))?
    if let Some(have) = registry::read(key, name)? {
        if matches(have, want) { return Ok(CheckResult::AlreadyConfigured) }
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = param_str(params, "key", "")
    let name = param_str(params, "name", "")
    if key == "" || name == "" { return Err("missing 'key' or 'name' parameter") }
    let kind = param_str(params, "kind", "sz")
    let want = desired(param_str(params, "data", ""), kind)?
    log::info("writing registry value " + key + "\\" + name)
    registry::create_key(key)?
    registry::write(key, name, want, kind)?
    Ok(ApplyResult::Success)
}
