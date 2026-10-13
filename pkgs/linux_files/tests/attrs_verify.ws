use value
use shell

fn stat(p: string) -> Result[string, string] {
    let out = shell::bash("stat -L -c '%a %u %g' -- '" + p + "'", Value::Null)?
    if !out.success { return Err("stat " + p + ": " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn expect(p: string, want: string) -> Result[unit, string] {
    let got = stat(p)?
    if got != want { return Err(p + ": expected '" + want + "', got '" + got + "'") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    expect("/tmp/cw-attrs/named.txt", "640 1234 1234")?
    expect("/tmp/cw-attrs/numeric.txt", "600 4321 4321")?
    expect("/tmp/cw-attrs/real.txt", "644 1234 0")?
    expect("/tmp/cw attrs/sub dir", "2775 0 1234")?
    // setgid on the parent hands its group to the new file
    expect("/tmp/cw attrs/sub dir/a b.txt", "600 0 1234")?
    // the link itself is untouched: still a link, still pointing at real.txt
    let link = shell::bash("[ \"$(readlink /tmp/cw-attrs/link.txt)\" = /tmp/cw-attrs/real.txt ]", Value::Null)?
    if !link.success { return Err("link.txt is no longer the original symlink") }
    Ok(true)
}
