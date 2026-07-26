use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // flatpak itself must list the remote the test added.
    Ok(shell::bash("flatpak remotes | awk '{{print $1}}' | grep -Fxq flathub", Value::Null)?.success)
}
