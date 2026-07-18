use value
use fs
use registry

fn verify(facts: Value) -> Result[bool, string] {
    let st = registry::read("HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State", "ImageState")?
    if let Some(v) = st {
        return Ok(
            v.as_string().unwrap_or("").trim() == "IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE" &&
            fs::is_file("C:\\Windows\\System32\\Sysprep\\unattend.xml")
        )
    }
    Ok(false)
}
