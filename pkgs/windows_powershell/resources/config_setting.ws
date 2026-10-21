use value
use json
use common
use config_file

fn get_at(doc: Value, keys: List[string], idx: int) -> Option[Value] {
    let cur = doc.get(keys[idx])
    if cur.is_none() { return None }
    if idx == keys.len() - 1 { return cur }
    get_at(cur.unwrap(), keys, idx + 1)
}

fn set_at(doc: Value, keys: List[string], idx: int, val: Value) -> Value {
    let m = if let Some(mm) = doc.as_map() { mm } else { #{} }
    let k = keys[idx]
    if idx == keys.len() - 1 {
        m[k] = val
    } else {
        let child = if let Some(c) = m.get(k) { c } else { Value::Map(#{}) }
        m[k] = set_at(child, keys, idx + 1, val)
    }
    Value::Map(m)
}

// Rebuilds the map without the key rather than calling remove(), whose
// Option result would be dropped on the floor.
fn del_at(doc: Value, keys: List[string], idx: int) -> Value {
    let m = if let Some(mm) = doc.as_map() { mm } else { #{} }
    let k = keys[idx]
    let out: Map[string, Value] = #{}
    for existing in m.keys() {
        if existing != k {
            out[existing] = m[existing]
        } else if idx != keys.len() - 1 {
            out[existing] = del_at(m[existing], keys, idx + 1)
        }
    }
    Value::Map(out)
}

// Only dots split. A module-qualified key such as
// `Microsoft.PowerShell:ExecutionPolicy` is one literal key, which is what
// literal_key is for.
fn key_parts(params: Value) -> Result[List[string], string] {
    let key = common::param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    if common::param_bool(params, "literal_key", false) { return Ok([key]) }
    Ok(key.split("."))
}

fn desired_value(params: Value) -> Result[Value, string] {
    let raw = common::param_str(params, "value", "")
    let kind = common::param_str(params, "value_type", "string")
    if kind == "string" { return Ok(Value::String(raw)) }
    if kind == "bool" {
        let normal = raw.trim().to_lower()
        if normal == "true" { return Ok(Value::Bool(true)) }
        if normal == "false" { return Ok(Value::Bool(false)) }
        return Err("value_type :bool needs true or false, got '" + raw + "'")
    }
    if kind == "int" {
        if let Some(n) = raw.trim().parse_int() { return Ok(Value::Int(n)) }
        return Err("value_type :int needs a whole number, got '" + raw + "'")
    }
    if kind == "list" {
        let items: List[Value] = []
        for part in raw.split(",") {
            let trimmed = part.trim()
            if trimmed != "" { items.push(Value::String(trimmed)) }
        }
        return Ok(Value::List(items))
    }
    if kind == "json" { return json::parse(raw) }
    Err("unknown 'value_type' '" + kind + "'")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let keys = key_parts(params)?
    let present = common::want_present(params)?
    let wanted = if present { Some(desired_value(params)?) } else { None }
    let resolved = config_file::config_path(params)?
    if resolved.is_none() {
        if present { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // An unreadable file is drift; apply says why it cannot rewrite it.
    let read = config_file::read_doc(config_file::user_root(params), resolved.unwrap())
    if read.is_err() { return Ok(CheckResult::NotConfigured) }
    let current = get_at(read.unwrap(), keys, 0)
    if let Some(want) = wanted {
        if let Some(existing) = current {
            if config_file::same_value(existing, want) { return Ok(CheckResult::AlreadyConfigured) }
        }
        return Ok(CheckResult::NotConfigured)
    }
    if current.is_none() { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let keys = key_parts(params)?
    let file = config_file::require_config_path(params)?
    let doc = config_file::read_doc(config_file::user_root(params), file)?
    let updated = if common::want_present(params)? {
        set_at(doc, keys, 0, desired_value(params)?)
    } else {
        del_at(doc, keys, 0)
    }
    config_file::write_doc(config_file::user_root(params), file, updated)?
    Ok(ApplyResult::Success)
}
