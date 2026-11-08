use value
use fs
use json

fn verify(facts: Value) -> Result[bool, string] {
    for name in ["remove", "last", "configured"] {
        let doc = json::parse(fs::read("/tmp/cfw42-module/" + name + ".json")?)?
        if doc.get("Sentinel").unwrap_or(Value::Null).as_int().unwrap_or(0) != 17 {
            return Err(name + ": unrelated setting lost")
        }
        let entry = doc.get("PSModulePath")
        if name == "remove" {
            if entry.unwrap_or(Value::Null).as_string().unwrap_or("") != "/keep/one:/keep/two" {
                return Err("remaining search paths or order changed")
            }
        } else if entry.is_some() { return Err(name + ": final path key survived") }
    }
    if fs::exists("/tmp/cfw42-module/missing.json") { return Err("removal created a missing file") }
    Ok(true)
}
