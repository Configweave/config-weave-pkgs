use value
use shell

fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("apk info -e " + name + " >/dev/null 2>&1", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    if installed("xz-libs")? { return Err("xz-libs should be removed") }
    if installed("xz")? { return Err("xz, which needs xz-libs, should be removed with it") }
    Ok(true)
}
