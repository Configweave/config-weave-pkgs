use value
use fs
use registry

fn uninstall_key(id: string) -> string { "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\" + id }

fn read_str(key: string, name: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, name)? { return Ok(v.as_string().unwrap_or("")) }
    Ok("")
}

fn expect_value(key: string, name: string, want: string) -> Result[unit, string] {
    let have = read_str(key, name)?
    if have != want { return Err(key + " " + name + " is '" + have + "', expected '" + want + "'") }
    Ok(())
}

fn expect_gone(what: string, gone: bool) -> Result[unit, string] {
    if !gone { return Err(what + " still exists") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    // 7-Zip, downloaded and kept in the per-URL cache as its MSI source.
    if !fs::exists("C:\\Program Files\\7-Zip\\7z.exe") { return Err("7-Zip is not installed") }
    if fs::glob("C:\\ProgramData\\config-weave\\installers\\*\\7z2409-x64.msi")?.is_empty() {
        return Err("the 7-Zip MSI was not kept in the installer cache")
    }
    // The minor upgrade moved cw-a to 1.1.0 under the same ProductCode.
    expect_value(uninstall_key("{{C0DE000A-0000-4000-8000-00000000C0DE}}"), "DisplayVersion", "1.1.0")?
    // cw-b got its property from the command line and CWEXTRA from the
    // transform.
    expect_value("HKLM\\SOFTWARE\\ConfigWeaveTest\\cw-b", "Value", "from-property")?
    expect_value("HKLM\\SOFTWARE\\ConfigWeaveTest\\cw-b", "Extra", "from-transform")?
    // cw-c was removed through its alt_product_id.
    expect_gone("cw-c's Uninstall key", !registry::key_exists(uninstall_key("{{C0DE000C-0000-4000-8000-00000000C0DE}}"))?)?

    if !fs::exists("C:\\weave-exe\\cmd-marker.txt") { return Err("the cmd.exe installer did not write its marker") }
    expect_value("HKLM\\SOFTWARE\\ConfigWeaveTest\\exe-sha", "Installed", "1")?
    expect_value(uninstall_key("cw-exe"), "DisplayVersion", "2.0")?
    // The range step ran its installer; the satisfied one did not touch cw-exe3.
    expect_value("HKLM\\SOFTWARE\\ConfigWeaveTest\\VC\\Runtimes\\x64", "Version", "v14.40.33810.00")?
    expect_value(uninstall_key("cw-exe3"), "DisplayVersion", "1.5.2")?
    expect_gone("cw-exe2's Uninstall key", !registry::key_exists(uninstall_key("cw-exe2"))?)?
    expect_gone("C:\\weave-exe\\marker.txt", !fs::exists("C:\\weave-exe\\marker.txt"))?
    Ok(true)
}
