use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    // cwdev's own extensions directory, not SYSTEM's.
    if fs::glob("C:\\Users\\cwdev\\.vscode\\extensions\\config-weave.cw-test-0.0.1*")?.is_empty() { return Err("cw-test 0.0.1 is not in cwdev's extensions directory") }
    if !fs::glob("C:\\Windows\\System32\\config\\systemprofile\\.vscode\\extensions\\config-weave.cw-test*")?.is_empty() { return Err("cw-test went into SYSTEM's profile") }
    if fs::glob("C:\\Windows\\System32\\config\\systemprofile\\.vscode\\extensions\\editorconfig.editorconfig-0.18.2*")?.is_empty() { return Err("EditorConfig 0.18.2 is not in SYSTEM's extensions directory") }
    Ok(true)
}
