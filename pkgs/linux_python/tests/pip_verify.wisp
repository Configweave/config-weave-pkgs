use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let gone = shell::bash("pip3 show cwtest >/dev/null 2>&1", Value::Null)?
    if gone.success { return Err("cwtest should have been uninstalled") }
    let pip = shell::bash("pip3 show pip >/dev/null 2>&1", Value::Null)?
    if !pip.success { return Err("pip itself should still be installed") }
    Ok(true)
}
