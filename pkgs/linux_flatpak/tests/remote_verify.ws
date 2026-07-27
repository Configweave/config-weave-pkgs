use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // flatpak itself must list the remote the test added.
    if !shell::bash("flatpak remotes | awk '{{print $1}}' | grep -Fxq flathub", Value::Null)?.success {
        return Ok(false)
    }
    // ... and `updated` must have left its window stamp behind.
    Ok(fs::is_file("/var/lib/config-weave/flatpak-updated-system"))
}
