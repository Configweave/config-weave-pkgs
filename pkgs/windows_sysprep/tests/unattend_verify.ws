use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let x = fs::read("/tmp/cw-unattend/unattend.xml")?
    let raw = fs::read("/tmp/cw-unattend/raw.xml")?
    Ok(
        x.contains("<ProtectYourPC>3</ProtectYourPC>") &&
        x.contains("<Value>P@ss&lt;&amp;&gt;&apos;&quot;w</Value>") &&
        x.contains("<LogonCount>3</LogonCount>") &&
        x.contains("<Username>Administrator</Username>") &&
        x.contains("<Order>2</Order>") &&
        x.contains("<CommandLine>cmd /c echo a &amp; echo b</CommandLine>") &&
        x.contains("<InputLocale>0409:00000409</InputLocale>") &&
        x.contains("<TimeZone>AUS Eastern Standard Time</TimeZone>") &&
        x.contains("pass=\"oobeSystem\"") &&
        raw.contains("urn:schemas-microsoft-com:unattend") &&
        !fs::exists("/tmp/cw-unattend/ghost.xml") &&
        !fs::exists("/tmp/cw-unattend/x.xml")
    )
}
