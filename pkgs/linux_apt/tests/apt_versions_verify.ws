use value
use shell

// "<status> <version>" as dpkg records it, "" when dpkg has no record.
fn state(name: string) -> Result[string, string] {
    let out = shell::bash("dpkg-query -W -f='${{db:Status-Status}} ${{Version}}' " + name + " 2>/dev/null", Value::Null)?
    Ok(out.stdout.trim())
}

fn expect(name: string, want: string) -> Result[unit, string] {
    let got = state(name)?
    if got != want { return Err(name + ": expected '" + want + "', dpkg says '" + got + "'") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    expect("cw-rc", "installed 1.0")?
    expect("cw-pin", "installed 1.0")?
    let gone = state("cw-gone")?
    if gone != "" && gone != "not-installed" { return Err("cw-gone should be removed, dpkg says '" + gone + "'") }
    expect("cw-held", "installed 2.0")?
    // the guard refused, so both are still there
    expect("cw-base", "installed 1.0")?
    expect("cw-dep", "installed 1.0")?
    for n in ["cw-base2", "cw-dep2"] {
        let s = state(n)?
        if s != "" && s != "not-installed" { return Err(n + " should be removed, dpkg says '" + s + "'") }
    }
    Ok(true)
}
