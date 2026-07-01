use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    // Telnet-Client drops telnet.exe into System32 once installed.
    Ok(fs::exists("C:\\Windows\\System32\\telnet.exe"))
}
