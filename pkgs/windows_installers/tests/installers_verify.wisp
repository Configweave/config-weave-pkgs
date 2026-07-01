use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    // The 7-Zip MSI lands 7z.exe under Program Files; the exe_installer
    // step's cmd.exe "installer" writes the marker its creates guard names.
    Ok(fs::exists("C:\\Program Files\\7-Zip\\7z.exe") && fs::exists("C:\\weave-exe-marker.txt"))
}
