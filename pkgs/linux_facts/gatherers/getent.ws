use value
use getent_common

fn param_str(params: Value, key: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn gather(params: Value) -> Result[Value, string] {
    getent_common::lookup(param_str(params, "database"), param_str(params, "key"))
}
