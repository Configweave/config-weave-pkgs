use value
use fs

fn mode_is_private(p: string) -> Result[bool, string] {
    let meta = fs::metadata(p)?
    if let Some(m) = meta.get("mode") {
        if let Some(mode) = m.as_int() {
            if mode % 512 == 384 { return Ok(true) }
            return Err(p + " has mode " + str(mode % 512) + ", expected 0600 (384)")
        }
    }
    Err(p + " reports no mode")
}

fn has(p: string, x: string, want: string) -> Result[bool, string] {
    if x.contains(want) { return Ok(true) }
    Err(p + " lacks " + want)
}

fn lacks(p: string, x: string, unwanted: string) -> Result[bool, string] {
    if !x.contains(unwanted) { return Ok(true) }
    Err(p + " still contains " + unwanted)
}

fn verify(facts: Value) -> Result[bool, string] {
    let full = "/tmp/cw-unattend/unattend.xml"
    let x = fs::read(full)?
    has(full, x, "<ProtectYourPC>3</ProtectYourPC>")?
    has(full, x, "<HideLocalAccountScreen>true</HideLocalAccountScreen>")?
    has(full, x, "processorArchitecture=\"amd64\"")?
    // base64(UTF-16LE(password + element name)), computed independently.
    has(full, x, "<AdministratorPassword><Value>UABAAHMAcwA8ACYAPgAnACIAdwBBAGQAbQBpAG4AaQBzAHQAcgBhAHQAbwByAFAAYQBzAHMAdwBvAHIAZAA=</Value><PlainText>false</PlainText>")?
    has(full, x, "<Password><Value>UABAAHMAcwA8ACYAPgAnACIAdwBQAGEAcwBzAHcAbwByAGQA</Value><PlainText>false</PlainText>")?
    lacks(full, x, "P@ss")?
    lacks(full, x, "<PlainText>true")?
    has(full, x, "<LogonCount>3</LogonCount>")?
    has(full, x, "<Username>Administrator</Username>")?
    has(full, x, "<Order>2</Order>")?
    has(full, x, "<CommandLine>cmd /c echo a &amp; echo b</CommandLine>")?
    has(full, x, "<InputLocale>0409:00000409</InputLocale>")?
    has(full, x, "<TimeZone>AUS Eastern Standard Time</TimeZone>")?
    has(full, x, "pass=\"oobeSystem\"")?
    mode_is_private(full)?

    let other = "/tmp/cw-unattend/other.xml"
    let o = fs::read(other)?
    has(other, o, "processorArchitecture=\"arm64\"")?
    has(other, o, "<Username>deploy</Username>")?
    // A non-BMP character exercises the surrogate-pair path.
    has(other, o, "<Password><Value>QQB1AHQAbwA92ADecAB3AFAAYQBzAHMAdwBvAHIAZAA=</Value><PlainText>false</PlainText>")?
    lacks(other, o, "<OOBE>")?
    lacks(other, o, "AdministratorPassword")?

    let noacct = "/tmp/cw-unattend/noaccount.xml"
    let n = fs::read(noacct)?
    has(noacct, n, "<HideEULAPage>true</HideEULAPage>")?
    lacks(noacct, n, "HideLocalAccountScreen")?

    let drift = "/tmp/cw-unattend/drift.xml"
    let d = fs::read(drift)?
    has(drift, d, "<TimeZone>UTC</TimeZone>")?
    mode_is_private(drift)?

    let raw = fs::read("/tmp/cw-unattend/raw.xml")?
    has("raw.xml", raw, "urn:schemas-microsoft-com:unattend")?
    if fs::exists("/tmp/cw-unattend/old.xml") { return Err("old.xml still exists after ensure = :absent") }
    if fs::exists("/tmp/cw-unattend/ghost.xml") { return Err("ghost.xml was created") }
    for bad in ["x.xml", "y.xml", "z.xml"] {
        if fs::exists("/tmp/cw-unattend/" + bad) { return Err(bad + " was written by a rejected step") }
    }
    Ok(true)
}
