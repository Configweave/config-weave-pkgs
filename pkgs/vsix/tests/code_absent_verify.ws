use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    // An uninstalled extension's directory can linger until VS Code next
    // cleans up, so the CLI's own registry (extensions.json) is checked.
    for f in ["C:\\Users\\cwdev\\.vscode\\extensions\\extensions.json", "C:\\Windows\\System32\\config\\systemprofile\\.vscode\\extensions\\extensions.json"] {
        if fs::exists(f) {
            let text = fs::read(f)?.to_lower()
            if text.contains("config-weave.cw-test") || text.contains("editorconfig.editorconfig") { return Err(f + " still lists an extension") }
        }
    }
    Ok(true)
}
