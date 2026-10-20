use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    if !common::instances("*", "", false)?.is_empty() { return Err("a Visual Studio instance is still installed") }
    Ok(true)
}
