use value
use shell

fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("rpm -q " + name + " >/dev/null 2>&1", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    if installed("timezone")? { return Err("timezone should be removed") }
    if !installed("ncurses-utils")? || !installed("aaa_base")? { return Err("the guard should have kept ncurses-utils and aaa_base") }
    Ok(true)
}
