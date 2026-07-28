use value
use fs
use path

fn installed(name: string, version: string) -> bool {
    let base = "/cwhome3/.local/share/powershell/Modules"
    let dir = path::join(path::join(base, name), version)
    fs::is_file(path::join(dir, name + ".psd1"))
}

fn verify(facts: Value) -> Result[bool, string] {
    if !installed("CwLocalDir", "2.1.0") { return Err("the directory install did not land in <Name>/<Version>/") }
    if !installed("CwLocalZip", "1.4.2") { return Err("the zip install did not land in <Name>/<Version>/, or strip_root did not drop the wrapper folder") }
    // strip_root must not have left the archive's wrapper directory behind.
    if fs::exists("/cwhome3/.local/share/powershell/Modules/CwLocalZip/1.4.2/CwLocalZip") {
        return Err("strip_root left the archive's top-level directory in place")
    }
    if fs::exists("/cwhome3/.local/share/powershell/Modules/CwSeededManual") {
        return Err("the hand-installed module was not removed")
    }
    Ok(true)
}
