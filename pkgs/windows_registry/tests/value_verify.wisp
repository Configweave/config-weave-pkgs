use value
use registry

fn verify(facts: Value) -> Result[bool, string] {
    let greeting = registry::read("HKLM\\Software\\ConfigWeaveTest", "greeting")?
    if let Some(v) = greeting {
        if v.as_string().unwrap_or("") != "hello from config-weave" { return Ok(false) }
    } else {
        return Ok(false)
    }
    let answer = registry::read("HKLM\\Software\\ConfigWeaveTest", "answer")?
    if let Some(v) = answer {
        if v.as_int().unwrap_or(0) != 42 { return Ok(false) }
    } else {
        return Ok(false)
    }
    Ok(true)
}
